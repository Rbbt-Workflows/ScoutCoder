require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'tmpdir'

# ---------------------------------------------------------------------------
# Permanent regression tests for the round-7 `entity` / `entity_property`
# path kinds in lib/ScoutCoder/path_kinds.rb:
#
#   1. the `promotion_post_move` HOOK side effects (paired-test relocation),
#   2. the TRUST BOUNDARY between engine-authorized endpoints and the
#      trusted-plugin hook, and
#   3. the entity-before-property LOADER ORDERING contract.
#
# DESIGN DECISION: (a) parameterized roots, NOT (b) real-root fixtures.
# Every test builds its own LLM::Agent, registers a COPY of the production
# kind definition whose `roots` point into a Dir.mktmpdir sandbox, and swaps
# the module constant ScoutCoder::PATH_KIND_ROOT to that sandbox for the
# duration of the exercise (restored in `ensure`). This works because the
# production hook lambdas resolve PATH_KIND_ROOT at CALL time (they close
# over the ScoutCoder lexical scope, not over a value), which is proven by
# tmp/path_kinds/round7/regression/out/const_swap_probe.txt: the registered
# copy's hook is the IDENTICAL object as the production lambda
# (`equal? == true`) and all of its writes land inside the sandbox while the
# real tree stays untouched. Consequence: no refactor of path_kinds.rb or of
# the read-only engine was needed, so the recorded probe evidence from
# tmp/path_kinds/round7/ops5b/ (matrix + trust_d) still describes the code
# under test; no re-record was necessary.
#
# TRUST-BOUNDARY FRAMING (this is the contract under test, worded exactly):
#   - The ENGINE (scout-ai path.rb#path_promote) authorizes and moves ONLY
#     the primary source and the primary destination of a promotion, both of
#     which must lie under the kind's declared `roots`.
#   - The paired-test relocation is performed by the workflow-supplied
#     `promotion_post_move` hook, i.e. TRUSTED-PLUGIN behavior. It is NOT an
#     engine-authorized endpoint: `path_authorize!` on the paired-test
#     destination is DENIED (outside the kind roots). No test below may be
#     read as "the engine moved the paired test".
#
# Recorded evidence already covering adjacent ground (do not duplicate):
# tmp/path_kinds/round7/ops5b/ (B1-B8 promote matrix, D trust boundary,
# C ordering probes incl. the c4 wiring verdict that a promoted
# lib/ScoutCoder/entity/*.rb file is NOT auto-loaded by workflow.rb today).
# ---------------------------------------------------------------------------
class TestPathKinds < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)

  # Real-tree directories a promotion must never touch from here.
  REAL_ROOTS = [
    File.join(ROOT, 'share', 'entities'),
    File.join(ROOT, 'share', 'entity_properties'),
    File.join(ROOT, 'lib', 'ScoutCoder', 'entity'),
    File.join(ROOT, 'share', 'test', 'entity'),
    File.join(ROOT, 'share', 'test', 'entity_property'),
    File.join(ROOT, 'test', 'ScoutCoder', 'entity'),
    File.join(ROOT, 'share', 'test'),
    File.join(ROOT, 'test', 'ScoutCoder'),
    File.join(ROOT, 'share', 'python_tasks'),
    File.join(ROOT, 'python', 'tasks')
  ].freeze

  def setup
    @sandbox = Dir.mktmpdir('r7-path-kinds')
    @agent = LLM::Agent.new
    @agent.integrate_workflow_path_kinds(ScoutCoder)
    @saved_root = ScoutCoder::PATH_KIND_ROOT
    @real_before = snapshot_roots(REAL_ROOTS)
  end

  def teardown
    Dir.chdir(@saved_cwd) if @saved_cwd && Dir.pwd != @saved_cwd
    restore_kind_root
    if ScoutCoder.const_defined?(:PATH_KIND_PROJECT_ROOT, false)
      was_verbose = $VERBOSE
      $VERBOSE = nil
      ScoutCoder.send(:remove_const, :PATH_KIND_PROJECT_ROOT)
      $VERBOSE = was_verbose
    end
    FileUtils.rm_rf(@sandbox) if @sandbox
    assert_equal @real_before, snapshot_roots(REAL_ROOTS),
                 'real kind roots changed while a sandboxed test was running'
  end

  # ---------------------------------------------------------------- helpers

  # Swap ScoutCoder::PATH_KIND_ROOT to the sandbox AND confine the CWD there.
  # BOTH are needed since round 9's engine (4680bd9): the kind ROOTS are
  # still the declaration surface (registration pins them, resolve_path uses
  # them), while the ENGINE's path sandbox grant is the process CWD
  # (LLM::Sandbox.authorize_path root: Dir.pwd default — engine path.rb
  # passes no root:), so path_write/path_promote only authorize inside the
  # CWD. The promotion hooks additionally resolve paired-test paths through
  # the Scout `:current` map, also PWD-anchored. PATH_KIND_ROOT is swapped
  # for the tests that still exercise PATH_KIND_ROOT semantics directly
  # (fresh-process chdir hooks); everything runs under the sandbox CWD.
  def confine_kind_root_to_sandbox!
    confine_cwd_to_sandbox!
    swap_kind_root!(@sandbox)
  end

  # Confine the process working directory to the sandbox so Scout-map
  # lookups (`:current` map = "{PWD}/...") performed by the promotion hooks
  # resolve inside the sandbox. This is the direct-hook counterpart of
  # confine_kind_root_to_sandbox!: PATH_KIND_ROOT governs the kind roots,
  # the CWD governs the Scout-map test paths. Restored in teardown.
  def confine_cwd_to_sandbox!
    # Idempotent: a second confinement from inside the sandbox must not
    # overwrite @saved_cwd with the sandbox itself (teardown would then
    # chdir into the directory it is about to delete, leaving the next
    # test's setup with a deleted CWD — Errno::ENOENT getcwd when the
    # engine pins roots against the :current map).
    return if @saved_cwd && Dir.pwd == @sandbox
    @saved_cwd = Dir.pwd
    Dir.chdir(@sandbox)
  end

  def swap_kind_root!(value)
    was_verbose = $VERBOSE
    $VERBOSE = nil
    ScoutCoder.send(:remove_const, :PATH_KIND_ROOT)
    ScoutCoder.const_set(:PATH_KIND_ROOT, value)
    $VERBOSE = was_verbose
  end

  def restore_kind_root
    return if @saved_root.nil?
    was_verbose = $VERBOSE
    $VERBOSE = nil
    ScoutCoder.send(:remove_const, :PATH_KIND_ROOT) if ScoutCoder.const_defined?(:PATH_KIND_ROOT, false)
    ScoutCoder.const_set(:PATH_KIND_ROOT, @saved_root)
    $VERBOSE = was_verbose
    @saved_root = nil
  end

  # Register a copy of a production kind with sandbox roots. `drop_hook`
  # additionally removes promotion_post_move (the hookless control arm).
  def sandbox_kind!(kind, drop_hook: false)
    base = @agent.path_kind_definition(kind)
    copy = {}
    base.each { |k, v| copy[k] = v.is_a?(Hash) ? v.dup : v }
    copy['roots'] = {
      # Round-8 contract: roots are Scout Path-likes, pinned absolute at
      # registration. The engine's resolve_path takes root[path] on a Path
      # (annotated child, set_extension-safe); a plain String root yields an
      # unannotated File.join String that breaks set_extension.
      'tmp' => Path.setup(File.join(@sandbox, 'share', KIND_TMP_SUBDIR[kind] || 'tasks')),
      'project' => Path.setup(case kind
                             when 'test_file' then File.join(@sandbox, 'test', 'ScoutCoder')
                             when 'python_task' then File.join(@sandbox, 'python', 'tasks')
                             else File.join(@sandbox, 'lib', 'ScoutCoder', 'entity')
                             end)
    }
    # Round 11 (python test tier): the sandbox test_file copy carries the
    # python location root too, so python-tier cases run against the
    # sandbox instead of the production python/test tree.
    copy['roots']['python'] = Path.setup(File.join(@sandbox, 'python', 'test')) if kind == 'test_file'
    # Round-9 smoke contract: the fresh-process child must load the REAL
    # checkout's workflow.rb (task smoke needs the workflow; entity/property
    # smoke need Entity + the module). Drafts still come from the sandbox
    # roots above; only the child CWD points at the real checkout.
    copy['project_root'] = ROOT
    # The test_file smoke children must run in the REAL checkout (they load
    # ./workflow.rb), exactly like the task/entity smoke children; drafts
    # still live in the sandbox roots above.
    was_verbose = $VERBOSE
    $VERBOSE = nil
    ScoutCoder.const_set(:PATH_KIND_PROJECT_ROOT, ROOT)
    $VERBOSE = was_verbose
    copy.delete('promotion_post_move') if drop_hook # no-op now: hook removed at round-10 step 6
    probe_kind = "#{kind}_sandbox_probe"
    @agent.register_path_kind(probe_kind, copy)
    probe_kind
  end

  KIND_TMP_SUBDIR = {
    'entity' => 'entities',
    'entity_property' => 'entity_properties',
    'python_task' => 'python_tasks',
    'test_file' => 'test',
    'probe' => 'probes'
  }.freeze

  def tool(tool_name, args)
    h = {}
    args.each { |k, v| h[k.to_s] = v }
    tools = @agent.other_options[:tools]
    tools[tool_name].first.call(tool_name, h)
  end

  def write_draft(kind, path, content)
    tool('path_write', 'kind' => kind, 'path' => path,
                       'location' => 'tmp', 'content' => content)
  end

  # Round 11: write with an explicit location (python-tier cases).
  def write_draft_at(kind, path, content, location)
    tool('path_write', 'kind' => kind, 'path' => path,
                       'location' => location, 'content' => content)
  end

  # Smoke results come back through the path tool wrapper: a successful hook
  # returns its Hash, but a ScoutException (ParameterException) raised by the
  # hook is captured by the wrapper and returned as a JSON String carrying
  # 'exception'/'exception_line'. Normalize both shapes to a Hash.
  def smoke_result(kind:, path:, location: 'tmp')
    raw = tool('path_smoke', 'kind' => kind, 'path' => path, 'location' => location)
    Hash === raw ? raw : JSON.parse(raw)
  end

  # The smoke wrapper converts a hook-raised ScoutException into a JSON
  # String; this helper surfaces it back as the original ParameterException
  # so the FAIL-direction cases can assert on the message.
  def smoke_raises(kind:, path:, location: 'tmp')
    raw = tool('path_smoke', 'kind' => kind, 'path' => path, 'location' => location)
    parsed = Hash === raw ? raw : JSON.parse(raw)
    raise ParameterException, parsed['exception'] || parsed.inspect
    parsed
  end

  def promote(kind, path, overwrite: nil)
    args = { 'kind' => kind, 'path' => path }
    args['overwrite'] = overwrite unless overwrite.nil?
    raw = tool('path_promote', args)
    if raw.is_a?(String) && raw.include?('"exception"')
      begin
        parsed = JSON.parse(raw)
        return parsed if parsed.key?('exception') && !parsed.key?('ok')
      rescue JSON::ParserError
        # fall through
      end
    end
    raw
  end

  def snapshot_tree(root)
    return {} unless Dir.exist?(root)
    Dir.glob(File.join(root, '**', '*')).select { |p| File.file?(p) }.sort.each_with_object({}) do |p, h|
      h[p.sub("#{root}/", '')] = Digest::SHA256.file(p).hexdigest
    end
  end

  def snapshot_roots(roots)
    roots.each_with_object({}) { |r, h| h[r] = snapshot_tree(r) }
  end

  def entity_draft(name)
    <<~RUBY
      module #{name.capitalize}
        extend Entity
      end
    RUBY
  end

  def property_draft(entity, property)
    <<~RUBY
      module #{entity.capitalize}
        property :#{property} => :single do |prefix, suffix|
          "\#{prefix}\#{self}\#{suffix}"
        end
      end
    RUBY
  end

  def fresh_ruby(code, chdir: ROOT)
    bin = "require 'json'; #{code}"
    Open3.capture3({ 'BWRAP_PATH' => 'false' }, RbConfig.ruby, '-e', bin, chdir: chdir)
  end

  # --------------------------------------------------- entity hook surface
  #
  # Round-10 step 6: the paired-test RELOCATION hooks were REMOVED from the
  # source kinds (task/entity/entity_property). Test files are first-class
  # test_file resources that promote themselves through the test_file kind's
  # own promote path; a source-kind promotion moves ONLY the source file.
  # The rounds-6/7 relocation tests below were replaced by the new rule's
  # regression tests (canary + exact-moves); the trust-boundary control arm
  # (drop_hook) is now the ONLY behavior, so it moved into the main flow.

  # CANARY: a paired test file present at promotion time is left
  # BYTE-IDENTICAL in place across a source-kind promotion, and nothing
  # beyond src/dst moves.
  def test_entity_promotion_leaves_paired_test_untouched
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    name = "hooktest_#{SecureRandom.hex(4)}"
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity', "#{name}.rb")
    proj_paired = File.join(@sandbox, 'test', 'ScoutCoder', 'entity', "test_#{name}.rb")
    FileUtils.mkdir_p(File.dirname(tmp_paired))
    File.write(tmp_paired, "# paired entity test #{name}\n")
    paired_digest = Digest::MD5.file(tmp_paired).hexdigest

    deco = File.join(@sandbox, 'share', 'test', 'entity', "hooktest_other_#{SecureRandom.hex(3)}.rb")
    File.write(deco, "# decoration\n")

    write_draft(kind, name, entity_draft(name))
    before = snapshot_tree(@sandbox)

    r = promote(kind, name)

    assert_equal true, r['promoted']
    refute r.key?('post_move'), 'no promotion_post_move hook exists anymore'

    after = snapshot_tree(@sandbox)
    added = after.keys - before.keys
    removed = before.keys - after.keys
    assert_equal ["lib/ScoutCoder/entity/#{name}.rb"], added.sort,
                 "promotion wrote more than the destination: #{added}"
    assert_equal ["share/entities/#{name}.rb"], removed.sort,
                 "promotion removed more than the source: #{removed}"
    assert File.file?(tmp_paired), 'paired test must stay in place'
    assert_equal paired_digest, Digest::MD5.file(tmp_paired).hexdigest,
                 'paired test must be byte-identical after source promotion'
    refute File.exist?(proj_paired), 'source promotion must not create the promoted paired test'
    assert File.file?(deco), 'unrelated file must not move'
  end

  # Same rule through the entity_property kind: promotion moves exactly the
  # source draft; its paired test (tmp spelling) is untouched.
  def test_property_promotion_leaves_paired_test_untouched
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity_property')
    entity = "hooktest_ent_#{SecureRandom.hex(3)}"
    property = 'hooklabel'
    vpath = "#{entity}/#{property}"
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity_property', entity, "#{entity}.#{property}.rb")
    FileUtils.mkdir_p(File.dirname(tmp_paired))
    File.write(tmp_paired, "# paired property test #{entity}.#{property}\n")
    paired_digest = Digest::MD5.file(tmp_paired).hexdigest

    write_draft(kind, vpath, property_draft(entity, property))
    before = snapshot_tree(@sandbox)

    r = promote(kind, vpath)

    assert_equal true, r['promoted']
    refute r.key?('post_move'), 'no promotion_post_move hook exists anymore'

    after = snapshot_tree(@sandbox)
    assert_equal ["lib/ScoutCoder/entity/#{entity}/#{property}.rb"], (after.keys - before.keys).sort
    assert_equal ["share/entity_properties/#{entity}/#{property}.rb"], (before.keys - after.keys).sort
    assert_equal paired_digest, Digest::MD5.file(tmp_paired).hexdigest,
                 'paired test must be byte-identical after source promotion'
  end

  # The advisory relocation-target mapping still exists (agents consult it
  # to promote test files themselves) and speaks the round-10 layout.
  def test_advisory_paired_test_targets_follow_new_layout
    t = ScoutCoder.path_kind_paired_test_relocation_targets('entity_property', %w[demo_widget tag_palette])
    assert_equal 'entity_property/demo_widget/demo_widget.tag_palette.rb', t['tmp']
    assert_equal 'entity/demo_widget/test_tag_palette.rb', t['project']

    t2 = ScoutCoder.path_kind_paired_test_relocation_targets('entity', %w[demo_widget])
    assert_equal 'entity/demo_widget.rb', t2['tmp']
    assert_equal 'entity/test_demo_widget.rb', t2['project']
  end

  # -------------------------------------------------------- trust boundary

  # What this proves, stated honestly for engine 4680bd9: since round-10
  # step 6 NO kind registers promotion_post_move, so a promotion moves ONLY
  # the primary source to the primary destination and leaves the paired
  # test untouched — there is no relocation path left anywhere.
  # Engine authorization note: path_authorize! resolves a kind
  # root (path.rb:1160-1169) but does NOT pass it to
  # LLM::Sandbox.authorize_path (path.rb:1171), whose effective grant is
  # root: Dir.pwd (sandbox.rb:76) plus Chat.allow_path thread grants. The
  # pre-drift premise "kind roots are the authorization set, so the
  # paired-test destination is DENIED" therefore no longer holds; both
  # destinations sit inside the sandbox CWD. What remains true and is
  # asserted below: the primary destination is authorized, and anything
  # outside the sandbox grant (CWD) is denied — the sandbox is active and
  # CWD-bounded even though the kind roots are not the grant set.
  def test_engine_authorized_set_excludes_paired_test_destination
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity', drop_hook: true)
    name = "hooktest_hookless_#{SecureRandom.hex(3)}"
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity', "#{name}.rb")
    proj_paired = File.join(@sandbox, 'test', 'ScoutCoder', 'entity', "test_#{name}.rb")
    src = File.join(@sandbox, 'share', 'entities', "#{name}.rb")
    dst = File.join(@sandbox, 'lib', 'ScoutCoder', 'entity', "#{name}.rb")

    FileUtils.mkdir_p(File.dirname(tmp_paired))
    File.write(tmp_paired, "# paired sentinel #{name}\n")

    write_draft(kind, name, entity_draft(name))
    r = promote(kind, name)

    assert_equal true, r['promoted']
    refute r.key?('post_move'), 'hookless control arm must report no hook result'
    assert File.file?(dst)
    refute File.exist?(src)
    assert File.file?(tmp_paired), 'engine alone must leave the paired test in place'
    assert_equal "# paired sentinel #{name}\n", File.read(tmp_paired)
    refute File.exist?(proj_paired), 'engine alone must not create the promoted paired test'

    # Engine endpoint authorization (round-11 re-baselined): since the
    # engine's authorization-root fix (68add84 + the in-flight list/dispatch
    # threading), path_authorize! authorizes against the KIND'S PINNED ROOT
    # for the location, not the process CWD. The primary promotion
    # destination (inside the project root) is authorized; the paired-test
    # destination (outside every kind root) is DENIED — it was never an
    # engine-authorized endpoint, and the old "CWD grant" premise was a
    # pre-drift expectation. Paths outside the grant stay denied.
    assert_nothing_raised do
      @agent.path_authorize!(kind, dst, 'project', mode: :write)
    end
    assert_raise(ParameterException,
                 'paired-test destination is outside the kind roots and must be denied') do
      @agent.path_authorize!(kind, proj_paired, 'project', mode: :write)
    end
    assert_raise(ParameterException) do
      @agent.path_authorize!(kind, File.join(REAL_ROOTS.first, 'outside_sandbox.rb'),
                             'project', mode: :write)
    end
  end

  # (Removed at round-10 step 6 with the relocation hooks: the direct
  # hook-invocation arm for entity_property asserted exactly the behavior
  # that was deleted. The replacement regressions are the canary tests
  # above: source promotion leaves paired tests untouched.)

  # ------------------------------------------- round-9 smoke contracts

  # task smoke: workflow loads + task resolves + job CONSTRUCTS with
  # placeholders for required inputs only. Execution is never attempted
  # (the block below raises if it were).
  def test_task_smoke_constructs_job_without_executing
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('task')
    name = "smoke_ok_task_#{SecureRandom.hex(3)}"
    write_draft(kind, name, <<~RUBY)
      module #{ScoutCoder.send(:target_workflow_name)}
        desc 'smoke fixture'
        input :mode, :select, 'pick one', nil, select_options: %w[fast slow], required: true
        input :opt, :string, 'optional', 'dv'
        task :#{name} => :string do |mode, opt|
          raise 'EXECUTION ATTEMPTED'
        end
      end
    RUBY

    r = smoke_result(kind: kind, path: name)
    assert_equal true, r['ok']
    assert_equal 'construct', r['stage']
    assert_equal false, r['executed']
    assert_match(/required=\[.mode.\]/, r['stdout'])
    assert_equal name, r['task']
  end

  # task smoke FAIL: required input cannot be derived (select declared with
  # positional options -> Task#inputs yields nil options row) is a
  # ParameterException naming the stage, not a crash.
  def test_task_smoke_failure_raises_parameter_exception_with_stage
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('task')
    name = "smoke_fail_task_#{SecureRandom.hex(3)}"
    write_draft(kind, name, <<~RUBY)
      module #{ScoutCoder.send(:target_workflow_name)}
        desc 'bad select'
        input :mode, :select, 'bad', nil, %w[fast slow]
        task :#{name} => :string do |mode| 'x' end
      end
    RUBY

    r = smoke_result(kind: kind, path: name)
    m = r['exception'].to_s + r['message'].to_s
    assert_match(/smoke: task .* failed at stage=/, m)
  end

  # entity smoke: module defined AND registered in Entity::MODULES. A plain
  # module (no extend Entity) fails.
  def test_entity_smoke_registered_ok_and_plain_module_fails
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    good = "smoke_ent_#{SecureRandom.hex(3)}"
    bad  = "smoke_plain_#{SecureRandom.hex(3)}"
    # Module name must follow the generator convention (underscores ->
    # CamelCase, path_kind_entity_module_name), NOT String#capitalize.
    good_mod = good.split('_').collect(&:capitalize).join
    bad_mod  = bad.split('_').collect(&:capitalize).join
    write_draft(kind, good, "module #{good_mod}\n  extend Entity\nend\n")
    write_draft(kind, bad,  "module #{bad_mod}\n  def self.note; 'no entity'; end\nend\n")
    r = smoke_result(kind: kind, path: good)
    assert_equal true, r['ok']
    assert_equal 'register', r['stage']

    r = smoke_result(kind: kind, path: bad)
    m = r['exception'].to_s + r['message'].to_s
    assert_match(/failed at stage=register: entity module not registered/, m)
  end

  # entity_property smoke: registration + accessor resolution via
  # instance_method (UnboundMethod, never bound/called). A property whose
  # block performs IO/raises when invoked still smokes OK, and the marker
  # file proves no dispatch happened.
  def test_entity_property_smoke_resolves_without_dispatch
    confine_kind_root_to_sandbox!
    kind_e = sandbox_kind!('entity')
    kind_p = sandbox_kind!('entity_property')
    entity = "smoke_prop_ent_#{SecureRandom.hex(3)}"
    prop = 'boom'
    mod = entity.split('_').collect(&:capitalize).join

    write_draft(kind_e, entity, "module #{mod}\n  extend Entity\nend\n")
    marker = File.join(@sandbox, 'NO_DISPATCH_MARKER')
    write_draft(kind_p, "#{entity}/#{prop}", <<~RUBY)
      module #{mod}
        property :#{prop} => :single do |*args|
          File.write('#{marker}', 'DISPATCHED')
          raise 'DISPATCH ATTEMPTED'
        end
      end
    RUBY

    r = smoke_result(kind: kind_p, path: "#{entity}/#{prop}")
    assert_equal true, r['ok']
    assert_equal 'resolve', r['stage']
    assert_equal false, r['dispatched']
    refute File.exist?(marker), 'property block must never run during smoke'

    # FAIL direction: a draft whose body registers a DIFFERENT property
    # than the one addressed by the path (missing) fails at stage=register
    # with a ParameterException; nothing is dispatched.
    write_draft(kind_p, "#{entity}/missing", <<~RUBY)
      module #{mod}
        property :boom do |*args|
          raise 'DISPATCH ATTEMPTED'
        end
      end
    RUBY
    r = smoke_result(kind: kind_p, path: "#{entity}/missing")
    m = r['exception'].to_s + r['message'].to_s
    assert_match(/failed at stage=register: property not registered on \S+: missing/, m)
    refute File.exist?(marker), 'the failed smoke must still never dispatch'
  end

  # --------------------------------------------------- loader ordering

  def test_property_before_entity_load_fails_loudly_in_fresh_process
    confine_kind_root_to_sandbox!
    kind_entity = sandbox_kind!('entity')
    kind_property = sandbox_kind!('entity_property')
    entity = "hooktest_order_#{SecureRandom.hex(3)}"
    property = 'label'

    write_draft(kind_entity, entity, entity_draft(entity))
    write_draft(kind_property, "#{entity}/#{property}", property_draft(entity, property))
    promote(kind_entity, entity)
    promote(kind_property, "#{entity}/#{property}")

    eproj = File.join(@sandbox, 'lib', 'ScoutCoder', 'entity')

    out, _err, _st = fresh_ruby(<<~CODE)
      require 'scout'
      begin
        load File.join(#{eproj.inspect}, #{(entity + '/' + property + '.rb').inspect})
        puts 'LOADED'
      rescue Exception => e
        puts "RAISED \#{e.class}"
      end
    CODE

    # Loader-ordering contract: a property file must NEVER load before its
    # entity. The failure is loud, not a silent unregistration. NOTE: a raw
    # Kernel#load surfaces the underlying NoMethodError; loading through the
    # LiveWorkflow wrapper (scout-gear live.rb) wraps it in ScoutException
    # (recorded in tmp/notes/round7-ops5b.md, C1).
    assert_match(/RAISED (\w+)/, out)
    refute out.include?('LOADED')
    assert_equal 'NoMethodError', out[/RAISED (\w+)/, 1],
                 "ordering failure must stay loud; got: #{out.strip[0, 120].inspect}"
  end

  def test_entity_then_property_loads_and_dispatches_in_fresh_process
    confine_kind_root_to_sandbox!
    kind_entity = sandbox_kind!('entity')
    kind_property = sandbox_kind!('entity_property')
    entity = "hooktest_order_#{SecureRandom.hex(3)}"
    property = 'label'

    write_draft(kind_entity, entity, entity_draft(entity))
    write_draft(kind_property, "#{entity}/#{property}", property_draft(entity, property))
    promote(kind_entity, entity)
    promote(kind_property, "#{entity}/#{property}")

    eproj = File.join(@sandbox, 'lib', 'ScoutCoder', 'entity')

    out, err, _st = fresh_ruby(<<~CODE)
      require 'scout'
      begin
        load File.join(#{eproj.inspect}, #{(entity + '.rb').inspect})
        load File.join(#{eproj.inspect}, #{(entity + '/' + property + '.rb').inspect})
        e = #{entity.capitalize}.setup('smoke-id', #{entity.capitalize}, {})
        puts "DISPATCHED \#{e.label('a-', '-b')}"
      rescue Exception => ex
        puts "RAISED \#{ex.class}: \#{ex.message.to_s[0, 90]}"
      end
    CODE

    assert_equal 'DISPATCHED a-smoke-id-b', out.lines.map(&:strip).last,
                 "entity-then-property must load and dispatch; stderr: #{err[0, 200]}"
  end

  # =====================================================================
  # test_file kind (round 9, research/test-file-path-kind-guide.md §8)
  # =====================================================================

  TF_PASS = <<~RUBY
    require 'test/unit'
    class TfPassOk < Test::Unit::TestCase
      def test_ok; assert_equal 1, 1; end
    end
  RUBY

  TF_FAIL = <<~RUBY
    require 'test/unit'
    class TfFailOk < Test::Unit::TestCase
      def test_fails; assert_equal 1, 2; end
    end
  RUBY

  # Round 11 (python test tier): unittest sources for the python location.
  PY_TEST_PASS = <<~PY
    import unittest

    class TestPyPass(unittest.TestCase):
        def test_ok(self):
            self.assertEqual(1, 1)
  PY

  PY_TEST_FAIL = <<~PY
    import unittest

    class TestPyFail(unittest.TestCase):
        def test_fails(self):
            self.assertEqual(1, 2)
  PY

  TF_FAIL = <<~RUBY
    require 'test/unit'
    class TfFailOk < Test::Unit::TestCase
      def test_fails; assert_equal 1, 2; end
    end
  RUBY

  def tf_kind!
    confine_kind_root_to_sandbox!
    sandbox_kind!('test_file')
  end

  def tf_seed(name, source, tier = 'task')
    dir = File.join(@sandbox, 'share', 'test', tier)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.rb"), source)
  end

  # Round 11 (python test tier): seed a python-location test (physical
  # name test_<name>.py under python/test).
  def py_test_seed(name, source)
    dir = File.join(@sandbox, 'python', 'test')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "test_#{name}.py"), source)
  end

  def run_test_call(kind, path, scope, timeout: nil, location: nil)
    args = { 'kind' => kind, 'path' => path, 'scope' => scope }
    args['timeout_seconds'] = timeout if timeout
    args['location'] = location if location
    raw = tool('run_test', args)
    if raw.is_a?(String) && raw.include?('"exception"')
      begin
        parsed = JSON.parse(raw)
        return parsed if parsed.key?('exception')
      rescue JSON::ParserError
        # fall through
      end
    end
    Hash === raw ? raw : JSON.parse(raw)
  end

  def validate_result(kind, path)
    raw = tool('path_validate', 'kind' => kind, 'path' => path)
    Hash === raw ? raw : JSON.parse(raw)
  end

  # 1. capability/location surface; the aggregated run_test tool installs.
  #    Round 10: smoke is OFF for test_file (validate + run_test cover it).
  def test_test_file_kind_registers_expected_capabilities_and_locations
    defn = @agent.path_kind_definition('test_file')
    caps = defn.fetch('capabilities')
    %w[read write edit list move rename delete validate promote].each do |op|
      assert_equal true, caps[op], "#{op} must be enabled"
    end
    %w[patch test smoke].each { |op| refute caps[op], "#{op} must stay off" }
    assert_equal %w[tmp project python], defn.fetch('locations')
    assert defn.fetch('operations').key?('run_test'),
           'operations must register run_test so the aggregated tool installs'
    assert @agent.other_options[:tools].key?('run_test'),
           'the aggregated run_test tool must be installed on the agent'
  end

  # 2. resolve maps the virtual spelling to both locations, all tiers.
  def test_test_file_resolve_maps_both_sides
    confine_kind_root_to_sandbox!
    tmp = @agent.resolve_path('test_file', 'task/greet_user', 'tmp').to_s
    proj = @agent.resolve_path('test_file', 'task/greet_user', 'project').to_s
    assert_equal File.join(@sandbox, 'share', 'test', 'task', 'greet_user.rb'), tmp
    assert_equal File.join(@sandbox, 'test', 'ScoutCoder', 'tasks', 'test_greet_user.rb'), proj

    etmp = @agent.resolve_path('test_file', 'entity/demo', 'tmp').to_s
    eproj = @agent.resolve_path('test_file', 'entity/demo', 'project').to_s
    assert_equal File.join(@sandbox, 'share', 'test', 'entity', 'demo.rb'), etmp
    assert_equal File.join(@sandbox, 'test', 'ScoutCoder', 'entity', 'test_demo.rb'), eproj

    ptmp = @agent.resolve_path('test_file', 'entity_property/e/p', 'tmp').to_s
    pproj = @agent.resolve_path('test_file', 'entity_property/e/p', 'project').to_s
    assert_equal File.join(@sandbox, 'share', 'test', 'entity_property', 'e', 'e.p.rb'), ptmp
    # round-10 step 4: hierarchy-preserving project layout (D1/D2/D6)
    assert_equal File.join(@sandbox, 'test', 'ScoutCoder', 'entity', 'e', 'test_p.rb'), pproj

    itmp = @agent.resolve_path('test_file', 'integration/rt', 'tmp').to_s
    iproj = @agent.resolve_path('test_file', 'integration/rt', 'project').to_s
    assert_equal File.join(@sandbox, 'share', 'test', 'integration', 'rt.rb'), itmp
    # D6 closed: integration gets the uniform test_ prefix
    assert_equal File.join(@sandbox, 'test', 'ScoutCoder', 'integration', 'test_rt.rb'), iproj

    # Round 11 (python tier): the python location hosts the python_task
    # tier only, flat test_<name>.py under python/test.
    ytmp = @agent.resolve_path('test_file', 'python_task/greet', 'python').to_s
    assert_equal File.join(@sandbox, 'python', 'test', 'test_greet.py'), ytmp
    yus = @agent.resolve_path('test_file', 'python_task/my_task_name', 'python').to_s
    assert_equal File.join(@sandbox, 'python', 'test', 'test_my_task_name.py'), yus
  end

  # 3. list round-trips virtual spellings on the project side.
  # (Round 11: runs through the SANDBOX kind copy — the engine now resolves
  # and authorizes every list target against the kind's PINNED root, so
  # listing through the production kind while seeding a sandbox tree is
  # denied as outside_grants; the copy's root matches the seeded tree.)
  def test_test_file_list_round_trips_virtual_paths
    kind = tf_kind!
    proj = File.join(@sandbox, 'test', 'ScoutCoder')
    %w[tasks/greet_user.rb entity/test_demo.rb entity/e/test_p.rb
       integration/test_rt.rb helper/test_helper_tools.rb].each do |rel|
      FileUtils.mkdir_p(File.dirname(File.join(proj, rel)))
      File.write(File.join(proj, rel), "# fixture\n")
    end

    listed = @agent.path_list('kind' => kind, 'location' => 'project')
    assert_includes listed, 'task/greet_user'
    assert_includes listed, 'entity/demo'
    assert_includes listed, 'entity_property/e/p'
    assert_includes listed, 'integration/rt'
    assert_includes listed, 'helper/helper_tools'
    assert listed.none? { |p| p.include?('tasks/') || p.include?('test_') },
           "project listing must be un-prefixed virtual spellings: #{listed.inspect}"
  end

  # 4. validate is static-only: no child process may spawn (a body that would
  # write a marker file if executed proves execution never happened).
  def test_test_file_validate_static_only
    kind = tf_kind!
    marker = File.join(@sandbox, 'EXECUTED_MARKER')
    tf_seed('exec_trap', "File.write(#{marker.inspect}, 'x')\n")
    r = validate_result(kind, 'task/exec_trap')
    assert_equal false, r['ok'], 'neither harness nor TestCase => error'
    refute File.exist?(marker), 'validate must never execute the target'

    tf_seed('valid', TF_PASS)
    assert_equal true, validate_result(kind, 'task/valid')['ok']

    tf_seed('harness_only', "require 'test/unit'\n")
    r = validate_result(kind, 'task/harness_only')
    assert_equal true, r['ok']
    assert r['warnings'].any? { |w| w =~ /no Test::Unit::TestCase subclass/ }

    tf_seed('wrong_prefix', "require 'test/unit'\nclass W < Test::Unit::TestCase\n  def test_w; assert true; end\nend\n")
    File.rename(File.join(@sandbox, 'share', 'test', 'task', 'wrong_prefix.rb'),
                File.join(@sandbox, 'share', 'test', 'task', 'test_wrong_prefix.rb'))

    r = validate_result(kind, 'task/test_wrong_prefix')
    assert_equal true, r['ok'], r.inspect
    assert r['warnings'].any? { |w| w =~ /`test_` prefix|test_ prefix/ }, r['warnings'].inspect
    refute File.exist?(marker)
  end

  # 5.-10. REMOVED in round 10 with the smoke capability (test_file smoke
  #    tests 5-10 of round 9). Decision: test_file has NO smoke; `validate`
  #    (static) plus `run_test` (executing, reporting `executed`/`passed`
  #    and exit status separately) cover every direction those tests
  #    exercised. The equivalent behavioral coverage now lives in the
  #    run_test tests below: pass/fail directions (11), aggregated
  #    directory scope (12), suite discovery + empty-is-error (13). The
  #    timeout direction is exercised through run_test's per-file
  #    timeout_seconds by TestFileSupport's own timeout handling.

  # 15. (round-10 step 3) canonical grammar: traversal and malformed shapes
  #     raise ParameterException BEFORE any filesystem inspection.
  # Recorder of File.exist?/directory?/file? calls. Prepended ONCE per
  # process (idempotent); individual tests arm/disarm it via @fs_recording,
  # so nothing leaks into later tests.
  FS_RECORDER = Module.new do
    define_method(:exist?) { |*a, &b| @fs_calls << :exist? if @fs_recording; super(*a, &b) }
    define_method(:directory?) { |*a, &b| @fs_calls << :directory? if @fs_recording; super(*a, &b) }
    define_method(:file?) { |*a, &b| @fs_calls << :file? if @fs_recording; super(*a, &b) }
  end

  def arm_fs_recorder!
    @fs_calls = []
    @fs_recording = true
    File.singleton_class.prepend(FS_RECORDER) unless File.singleton_class < FS_RECORDER
  end

  def disarm_fs_recorder!
    @fs_recording = false
  end

  # 18. (round-10 step 4) the single mapping authority round-trips every
  #     tier in both locations, underscore-bearing names included, and is
  #     injective (D1/D2/D6 regression).
  def test_test_file_mapping_authority_round_trips_and_is_injective
    confine_kind_root_to_sandbox!
    tf = ScoutCoder::PathKindTestFiles

    unders = %w[demo_widget my_task_name tag_palette feature_dir_with_underscores x_y_z]
    # task allows intermediates; entity/helper are 2-component; integration
    # 2 or 3; entity_property exactly 3 (all grammar-gated).
    virtuals = []
    %w[task].each do |t|
      unders.each { |n| virtuals << "#{t}/#{n}"; virtuals << "#{t}/dir_with_underscores/#{n}" }
    end
    %w[entity helper].each { |t| unders.each { |n| virtuals << "#{t}/#{n}" } }
    %w[integration].each { |t| unders.each { |n| virtuals << "#{t}/#{n}" << "#{t}/feat_dir_with_underscores/#{n}" } }
    unders.each { |e| unders.each { |p| virtuals << "entity_property/#{e}/#{p}" } }

    %w[tmp project].each do |loc|
      virtuals.each do |vp|
        fwd = tf.path_kind_map_forward_segments(vp.split('/'), loc)
        bck = tf.path_kind_map_back(fwd, loc)
        assert_equal vp, bck, "mapping not reversible [#{loc}] for #{vp} (via #{fwd})"
      end
    end
    # tmp entity_property nested spelling
    fwd = tf.path_kind_map_forward_segments(%w[entity_property demo_widget tag_palette], 'tmp')
    assert_equal 'entity_property/demo_widget/demo_widget.tag_palette.rb', fwd
    assert_equal 'entity_property/demo_widget/tag_palette', tf.path_kind_map_back(fwd, 'tmp')

    # injectivity per location
    %w[tmp project].each do |loc|
      seen = {}
      virtuals.each do |vp|
        fwd = tf.path_kind_map_forward_segments(vp.split('/'), loc)
        refute seen.key?(fwd), "#{loc} mapping collision: #{fwd} <- #{seen[fwd]} and #{vp}"
        seen[fwd] = vp
      end
    end

    # D2 classic pair must differ now
    a = tf.path_kind_map_forward_segments(%w[entity_property demo_widget widget], 'project')
    b = tf.path_kind_map_forward_segments(%w[entity demo_widget], 'project')
    refute_equal a, b, 'D2 pair must not collide under the hierarchical layout'

    # D1: task intermediates preserved project-side
    deep = tf.path_kind_map_forward_segments(%w[task dir1 dir2 name], 'project')
    assert_equal 'tasks/dir1/dir2/test_name.rb', deep

    # D6: integration uniform prefix project-side
    assert_equal 'integration/test_rt.rb',
                 tf.path_kind_map_forward_segments(%w[integration rt], 'project')
    assert_equal 'integration/feat/test_rt.rb',
                 tf.path_kind_map_forward_segments(%w[integration feat rt], 'project')
  end

  # 21. (round-10 step 6, sub-fix A) source-kind promotion moves ONLY the
  #     source file: no test file is created, moved or deleted as a side
  #     effect, and a pre-existing paired test stays byte-identical.
  def test_source_promotion_leaves_test_files_untouched
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    name = "canary_#{SecureRandom.hex(3)}"
    tmp_src = File.join(@sandbox, 'share', 'entities', "#{name}.rb")
    proj_src = File.join(@sandbox, 'lib', 'ScoutCoder', 'entity', "#{name}.rb")
    paired = File.join(@sandbox, 'share', 'test', 'entity', "#{name}.rb")
    FileUtils.mkdir_p(File.dirname(tmp_src))
    FileUtils.mkdir_p(File.dirname(paired))
    File.write(tmp_src, "module #{name.capitalize}\n  extend Entity\nend\n")
    paired_bytes = "# paired test v1\n"
    File.write(paired, paired_bytes)

    r = promote(kind, name, overwrite: true)
    assert File.exist?(proj_src), 'source promoted'
    assert File.exist?(tmp_src) == false || r['overwritten'], 'source moved'
    assert File.exist?(paired), 'paired test still in place'
    assert_equal paired_bytes, File.read(paired), 'paired test byte-identical'
    assert Dir[File.join(@sandbox, 'test', '**', '*')].empty?,
           'no file appeared under the project test tree'
  end

  # 22. (round-10 step 6, sub-fix A) the test_file kind owns its own
  #     promotion end-to-end (declarative destination, no post-move hook).
  def test_test_file_promotion_moves_only_the_test_file
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('test_file')
    tf_seed('moves_self', TF_PASS)
    r = promote(kind, 'task/moves_self', overwrite: true)
    assert_equal 'ok', r['post_move'] if r['post_move']
    assert File.exist?(File.join(@sandbox, 'test', 'ScoutCoder', 'tasks', 'test_moves_self.rb')),
           'promoted copy in hierarchical project layout'
    refute File.exist?(File.join(@sandbox, 'share', 'test', 'task', 'moves_self.rb')),
           'tmp draft moved away'
  end

  # 23. (round-10 step 6, sub-fix C) run_test schema: scope is OPTIONAL
  #     with default file; timeout_seconds bounds are enforced with
  #     ParameterException before any child process spawns.
  def test_run_test_scope_default_and_timeout_bounds
    kind = tf_kind!
    tf_seed('dflt', TF_PASS)

    # scope omitted -> default 'file'
    raw = tool('run_test', 'kind' => kind, 'path' => 'task/dflt')
    r = Hash === raw ? raw : JSON.parse(raw)
    assert_equal 'file', r['scope']
    assert_equal 1, r['count']
    assert_equal true, r['ok']

    # timeout bounds: below minimum and above maximum rejected. The engine
    # tool wrapper captures ScoutExceptions and returns a JSON String with
    # 'exception' — use the normalized tool result shape for BOTH sides.
    [{'timeout_seconds' => 0}, {'timeout_seconds' => -5},
     {'timeout_seconds' => ScoutCoder::TestFileSupport::MAX_TIMEOUT + 1},
     {'timeout_seconds' => 'soon'}].each do |bad|
      raw = tool('run_test', { 'kind' => kind, 'path' => 'task/dflt',
                               'scope' => 'file' }.merge(bad))
      r = Hash === raw ? raw : JSON.parse(raw)
      assert r.key?('exception'), "bounds violation must fail: #{bad.inspect} -> #{r.inspect}"
      assert_match(/timeout_seconds/, r['exception'].to_s)
    end
  end

  # 20. (round-10 step 5) list honors prefixes: exact descendants only,
  #     empty on well-formed absence, ParameterException on malformed,
  #     file-shaped input, determinism, both locations (D3 regression).
  # (Round 11: runs through the SANDBOX kind copy — see the note above on
  # test_test_file_list_round_trips_virtual_paths.)
  def test_test_file_list_honors_prefixes
    kind = tf_kind!
    tmp_root = File.join(@sandbox, 'share', 'test')
    proj_root = File.join(@sandbox, 'test', 'ScoutCoder')
    # tmp fixtures
    %w[task/a.rb task/nested/b.rb entity/demo.rb entity_property/e/e.p.rb
       helper/helper_tools.rb integration/rt.rb other_open/x.rb].each do |rel|
      path = File.join(tmp_root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# fixture\n")
    end
    # project fixtures (hierarchical step-4 layout)
    %w[tasks/test_a.rb tasks/nested/test_b.rb entity/test_demo.rb
       entity/e/test_p.rb helper/test_helper_tools.rb integration/test_rt.rb
       other_open/test_x.rb].each do |rel|
      path = File.join(proj_root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# fixture\n")
    end

    list = ->(p, loc) { @agent.path_list('kind' => kind, 'path' => p, 'location' => loc) }

    %w[tmp project].each do |loc|
      everything = %w[entity/demo entity_property/e/p helper/helper_tools
                      integration/rt other_open/x task/a task/nested/b]
      # root selector (both spellings) == exact full set
      assert_equal everything, list.call('', loc), "[#{loc}] root listing"
      assert_equal everything, list.call('.', loc), "[#{loc}] dot selector"

      # tier prefix: exact descendants; entity tier excludes entity_property
      assert_equal %w[task/a task/nested/b], list.call('task', loc), "[#{loc}] task prefix"
      assert_equal ['entity/demo'], list.call('entity', loc), "[#{loc}] entity prefix"
      assert_equal ['entity_property/e/p'], list.call('entity_property', loc), "[#{loc}] entity_property prefix"
      assert_equal ['other_open/x'], list.call('other_open', loc), "[#{loc}] open-tier prefix"

      # nested prefix: descendants only, never siblings
      assert_equal ['task/nested/b'], list.call('task/nested', loc), "[#{loc}] nested prefix"
      assert_equal ['entity_property/e/p'], list.call('entity_property/e', loc), "[#{loc}] ep nested prefix"

      # file-shaped input: present -> [itself]; absent -> []
      assert_equal ['task/a'], list.call('task/a', loc), "[#{loc}] file present"
      assert_equal [], list.call('task/no_such_file', loc), "[#{loc}] file absent"

      # well-formed but missing prefix -> EMPTY (not an error)
      assert_equal [], list.call('no_such_tier', loc), "[#{loc}] missing tier"

      # malformed stays a grammar error
      e = assert_raise(ParameterException) { list.call('../escape', loc) }
      assert_match(/'..' is not allowed/, e.message)

      # determinism
      assert_equal list.call('', loc), list.call('', loc)

      # every entry resolves to an existing file under the location root
      root = loc == 'tmp' ? tmp_root : proj_root
      list.call('', loc).each do |v|
        phys = @agent.resolve_path(kind, v, loc).to_s
        assert File.file?(phys), "[#{loc}] #{v} must resolve to an existing file"
        assert phys.start_with?(root), "[#{loc}] #{v} resolved outside root: #{phys}"
      end
    end

    # Round 11 (python tier): the python location lists ONLY python_task
    # spellings, flat under python/test; the legacy test_ prefix is part of
    # the PHYSICAL spelling, not the virtual one.
    py_root = File.join(@sandbox, 'python', 'test')
    FileUtils.mkdir_p(py_root)
    %w[test_plain.py test_demo_widget.py test_my_task_name.py
       not_a_test.py].each do |f|
      File.write(File.join(py_root, f), "# fixture\n")
    end

    assert_equal %w[python_task/demo_widget python_task/my_task_name
                    python_task/plain],
                 list.call('', 'python'), 'python root listing'
    assert_equal %w[python_task/demo_widget python_task/my_task_name
                    python_task/plain],
                 list.call('.', 'python'), 'python dot selector'
    assert_equal ['python_task/my_task_name'], list.call('python_task/my_task_name', 'python')
    assert_equal [], list.call('task', 'python'), 'other tier at python is empty, not error'
    e = assert_raise(ParameterException) { list.call('../escape', 'python') }
    assert_match(/'..' is not allowed/, e.message)
  end

  # 19. (round-10 step 4) arity gates: entity/helper 3-component and
  #     integration 4-component shapes are ParameterExceptions (they would
  #     break reversibility against the entity_property hierarchy).
  def test_test_file_mapping_arity_gates_reject_ambiguous_shapes
    confine_kind_root_to_sandbox!
    ['entity/a/b', 'helper/a/b', 'integration/a/b/c'].each do |vp|
      e = assert_raise(ParameterException, "#{vp} must be rejected") do
        @agent.resolve_path('test_file', vp, 'project')
      end
      assert_match(/components/, e.message)
    end
    # accepted shapes still resolve
    assert_nothing_raised do
      @agent.resolve_path('test_file', 'entity/a', 'project')
      @agent.resolve_path('test_file', 'helper/a', 'project')
      @agent.resolve_path('test_file', 'integration/a/b', 'project')
    end
  end

  def test_test_file_grammar_rejects_malformed_paths_before_fs_inspection
    confine_kind_root_to_sandbox!
    arm_fs_recorder!
    bad = ['task/../outside.rb', '../escape', '..', 'a/../../b',
           'entity_property/../..', '/etc/passwd', 'task//double.rb',
           'task/trailing/', 'task/.', 'task/seg\\ment.rb']
    bad.each do |path|
      @fs_calls.clear
      e = assert_raise(ParameterException, "path #{path.inspect} must be rejected") do
        @agent.resolve_path('test_file', path, 'tmp')
      end
      assert @fs_calls.empty?,
             "path #{path.inspect} raised (#{e.message[0, 40]}...) but only after FS calls #{@fs_calls.inspect}"
    end
  ensure
    disarm_fs_recorder!
  end

  # 16. (round-10 step 3) entity_property arity: 4 components rejected (D4),
  #     1-2 component prefixes and the 3-component file shape stay valid.
  def test_test_file_grammar_entity_property_arity_and_prefix_shapes
    confine_kind_root_to_sandbox!
    assert_raise(ParameterException) do
      @agent.resolve_path('test_file', 'entity_property/a/b/extra', 'tmp')
    end
    assert_raise(ParameterException) do
      @agent.resolve_path('test_file', 'entity_property/a/b/c/d', 'project')
    end

    assert_equal File.join(@sandbox, 'share', 'test', 'entity_property'),
                 @agent.resolve_path('test_file', 'entity_property', 'tmp').to_s
    assert_equal File.join(@sandbox, 'share', 'test', 'entity_property', 'a'),
                 @agent.resolve_path('test_file', 'entity_property/a', 'tmp').to_s
    assert_equal File.join(@sandbox, 'share', 'test', 'entity_property', 'a', 'a.b.rb'),
                 @agent.resolve_path('test_file', 'entity_property/a/b', 'tmp').to_s
    # round-10 step 4: project side is hierarchy-preserving
    # entity/<entity>/test_<property>.rb (no underscore flattening, D2)
    assert_equal File.join(@sandbox, 'test', 'ScoutCoder', 'entity', 'a', 'test_b.rb'),
                 @agent.resolve_path('test_file', 'entity_property/a/b', 'project').to_s
    assert_equal File.join(@sandbox, 'test', 'ScoutCoder', 'entity', 'demo_widget', 'test_tag_palette.rb'),
                 @agent.resolve_path('test_file', 'entity_property/demo_widget/tag_palette', 'project').to_s
  end

  # 17. (round-10 step 3) symlink-aware root containment at resolve boundary.
  def test_test_file_containment_rejects_outside_symlink_and_allows_inside
    confine_kind_root_to_sandbox!
    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'test', 'task'))
    outside = Dir.mktmpdir('r10-containment-outside')
    canary = File.join(outside, 'canary.txt')
    File.write(canary, "R10-CANARY\n")
    link = File.join(@sandbox, 'share', 'test', 'task', 'outside_link')
    File.symlink(outside, link)

    # Round-10 step 4: file-shaped paths map to <name>.rb, so the
    # symlinked DIRECTORY itself is addressed through an intermediate
    # component; the containment walk then realpaths the symlink (which
    # exists) outside the root and rejects.
    e = assert_raise(ParameterException) do
      @agent.resolve_path('test_file', 'task/outside_link/canary', 'tmp')
    end
    assert_match(/outside the kind root/, e.message)

    assert_raise(ParameterException) do
      @agent.resolve_path('test_file', 'task/outside_link/deeper/child', 'tmp')
    end

    # legitimate inside-root symlink: no false positive (an intermediate
    # component through the symlink resolves back inside the root)
    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'test', 'entity'))
    File.symlink('../entity', File.join(@sandbox, 'share', 'test', 'task', 'insidelink'))
    resolved = @agent.resolve_path('test_file', 'task/insidelink/some_test', 'tmp').to_s
    assert resolved.start_with?(File.realpath(File.join(@sandbox, 'share', 'test'))),
           "inside-root symlink must stay inside the root: #{resolved}"

    assert_equal "R10-CANARY\n", File.read(canary), 'outside canary must be untouched'
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  # 11. run_test file scope, pass and fail directions, via the aggregated tool.
  def test_run_test_file_scope_pass_and_fail
    kind = tf_kind!
    tf_seed('alpha', TF_PASS)
    tf_seed('beta', TF_FAIL)

    r = run_test_call(kind, 'task/alpha', 'file')
    assert_equal 1, r['count']
    assert_equal true, r['ok']
    assert_equal 'clean_pass', r['results'].first['exit_class']
    assert_match(/1 tests?, 1 assertions?/, r['results'].first['summary'].to_s)

    f = run_test_call(kind, 'task/beta', 'file')
    assert_equal false, f['ok']
    assert_equal 'assertion_failure', f['results'].first['exit_class']
    assert_match(/assert/, f['results'].first['stdout'].to_s)
  end

  # 12. directory scope aggregates per-file results and counts.
  def test_run_test_directory_scope_aggregates
    kind = tf_kind!
    tf_seed('alpha', TF_PASS)
    tf_seed('beta', TF_FAIL)
    r = run_test_call(kind, 'task', 'directory')
    assert_equal 2, r['count']
    assert_equal false, r['ok'], 'one failing file => overall ok:false'
    assert_equal %w[alpha.rb beta.rb], r['results'].collect { |x| File.basename(x['file']) }.sort
    assert r['results'].all? { |x| x['ran'] }, 'both files must be reported'  end

  # 13. suite scope discovers BOTH locations; empty sandbox is an error.
  def test_run_test_suite_scope_discovers_both_sides_and_empty_is_error
    kind = tf_kind!
    tf_seed('alpha', TF_PASS)
    tf_seed('rt', TF_PASS, 'integration')
    proj = File.join(@sandbox, 'test', 'ScoutCoder', 'tasks')
    FileUtils.mkdir_p(proj)
    File.write(File.join(proj, 'test_alpha.rb'), TF_PASS)

    r = run_test_call(kind, '.', 'suite')
    assert_equal 3, r['count']
    tails = r['results'].collect { |x| x['file'].sub(%r{\A#{Regexp.escape(@sandbox)}/}, '') }.sort
    assert_equal ['share/test/integration/rt.rb', 'share/test/task/alpha.rb',
                  'test/ScoutCoder/tasks/test_alpha.rb'], tails

    # (Round 11: the empty-suite arm no longer chdirs into a foreign mktmpdir.
    # The engine now authorizes custom-operation paths against the pinned
    # kind root, so the probe must own EMPTY roots inside the sandbox for
    # the intended discovery error — not rely on a CWD the root never
    # covered. A fresh kind copy with empty roots supplies exactly that.)
    empty_kind = 'test_file_empty_probe'
    empty_copy = @agent.path_kind_definition('test_file').dup
    # The copy must be SELF-CONSISTENT: drop the production resolve hook (it
    # resolves through the 'test_file' registration and would hand back the
    # REAL roots, which the copy's pinned roots then deny) so resolution
    # flows through the copy's own pinned roots instead.
    empty_copy.delete('resolve')
    empty_copy['roots'] = {
      'tmp' => Path.setup(File.join(@sandbox, 'empty_suite_tmp')),
      'project' => Path.setup(File.join(@sandbox, 'empty_suite_proj')),
      'python' => Path.setup(File.join(@sandbox, 'empty_suite_py'))
    }
    @agent.register_path_kind(empty_kind, empty_copy)
    rr = run_test_call(empty_kind, '.', 'suite')
    assert_match(/no test files found|no test directories found/, rr['exception'].to_s)
  end

  # 14. promote rewrites the spelling via resolve; overwrite refusal intact.
  def test_test_file_promote_rewrites_spelling_via_resolve
    kind = tf_kind!
    tf_seed('greet_user', TF_PASS)
    src = File.join(@sandbox, 'share', 'test', 'task', 'greet_user.rb')
    dst = File.join(@sandbox, 'test', 'ScoutCoder', 'tasks', 'test_greet_user.rb')
    FileUtils.mkdir_p(File.dirname(dst))
    File.write(dst, '# pre-existing')

    r = promote(kind, 'task/greet_user')
    assert_match(/already exists/, r['exception'].to_s)
    assert File.file?(src), 'refused promotion must leave the source intact'

    r = promote(kind, 'task/greet_user', overwrite: true)
    assert File.file?(dst)
    assert_equal TF_PASS, File.read(dst), 'engine move rewrites the virtual spelling'
    refute File.exist?(src)
  end
  # --------------------------- round-9 step 6: `test` op removal alignment
  # Source kinds (task/entity/entity_property) drop the built-in `test`
  # operation: no capability key, no handler, agent has no path_test tool.
  # Relocation (promotion_post_move) is untouched — see tests above.
  def test_source_kinds_drop_test_operation_but_keep_relocation
    %w[task entity entity_property python_task].each do |k|
      raw = ScoutCoder::PATH_KINDS.fetch(k)
      refute raw.fetch('capabilities', {}).key?('test'),
             "#{k} must not declare a 'test' capability"
      refute raw.fetch('operations', {}).key?('test'),
             "#{k} must not register a 'test' handler"
      defn = @agent.path_kind_definition(k)
      caps = defn.fetch('capabilities')
      %w[validate smoke promote].each do |op|
        assert_equal true, caps[op], "#{k} must keep #{op}"
      end
      assert defn.key?('promotion_destination') ||
             defn.fetch('operations', {}).key?('promotion_post_move') ||
             raw.key?('promotion_post_move'),
             "#{k} must keep promotion wiring"
      assert_equal false, @agent.path_kind_capable?(k, 'test'),
                   "#{k} must not be capable of the removed 'test' op"
    end
    assert !@agent.other_options[:tools].key?('path_test'),
           'no path_test tool must be installed for the source kinds'
  end


  # =====================================================================
  # python_task kind (round 11) — registration, CRUD, validate, smoke,
  # promote, containment. Modeled on the task-kind coverage above; the
  # probes under tmp/path_kinds/round11/kind/ recorded the same matrix
  # before these permanent tests were written.
  # =====================================================================

  PY_GOOD = <<~PY
    '''Fixture task.'''
    import scout

    def py_fixture(name: str = "World") -> str:
        return f"hello {name}"

    scout.task(py_fixture)
  PY

  def py_kind!
    confine_kind_root_to_sandbox!
    sandbox_kind!('python_task')
  end

  def py_seed(name, source = PY_GOOD, location = 'tmp')
    root = location == 'tmp' ?
      File.join(@sandbox, 'share', 'python_tasks') :
      File.join(@sandbox, 'python', 'tasks')
    target = File.join(root, "#{name}.py")
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, source)
    target
  end

  def py_validate(kind, path, location = 'tmp')
    raw = tool('path_validate', 'kind' => kind, 'path' => path,
                                 'location' => location)
    Hash === raw ? raw : JSON.parse(raw)
  end

  # 1. registration: definition surface, capabilities, pinned roots.
  def test_python_task_kind_definition_surface
    raw = ScoutCoder::PATH_KINDS.fetch('python_task')
    assert_equal %w[tmp project], raw.fetch('locations')
    assert_equal 'tmp', raw.fetch('default_location')
    assert_equal 'py', raw.fetch('extension')
    assert_equal 'project', raw.fetch('promotion_destination')
    refute raw.fetch('capabilities', {}).key?('patch')
    refute raw.fetch('capabilities', {}).key?('test')

    defn = @agent.path_kind_definition('python_task')
    assert defn['roots']['tmp'].to_s.start_with?('/'), 'tmp root pinned absolute'
    assert defn['roots']['project'].to_s.start_with?('/'), 'project root pinned absolute'
    assert_match(%r{share/python_tasks\z}, defn['roots']['tmp'].to_s)
    assert_match(%r{python/tasks\z}, defn['roots']['project'].to_s)
    %w[read write edit list move rename delete validate smoke promote].each do |op|
      assert_equal true, defn.fetch('capabilities')[op], "#{op} capability"
    end
  end

  # 2. registration idempotence: double incorporation registers once.
  def test_python_task_registration_idempotent
    agent = LLM::Agent.new
    agent.integrate_workflow_path_kinds(ScoutCoder)
    agent.integrate_workflow_path_kinds(ScoutCoder)
    kinds = agent.path_kind_registry.keys
    assert_equal 1, kinds.count('python_task')
    assert kinds.include?('python_task')
  end

  # 3. generic CRUD, nested and underscore-bearing names at both locations.
  def test_python_task_generic_crud_round_trip
    kind = py_kind!
    names = %w[crud_probe under_scored2 nested/deep_probe]
    names.each { |n| write_draft(kind, n, PY_GOOD) }
    names.each { |n| py_seed(n, PY_GOOD, 'project') }

    listed = @agent.path_list('kind' => kind, 'location' => 'tmp')
    names.each { |n| assert listed.include?("#{n}.py"), "tmp listing missing #{n}" }    # NOTE (engine 3719551): engine-generic path_list returns entries with
    # their PHYSICAL extension (.py), unlike the test_file kind's custom
    # list hook which strips to virtual spellings. Consumers must resolve
    # the BARE name; a dotted listed spelling double-appends the extension.
    names.each { |n| assert listed.none? { |p| p =~ /\.py\.py\z/ },
                    'double-appended extension in listing' }
    listed_p = @agent.path_list('kind' => kind, 'location' => 'project')
    names.each { |n| assert listed_p.include?("#{n}.py"), "project listing missing #{n}" }

    # virtual -> physical round-trip through resolve
    names.each do |n|
      resolved = @agent.resolve_path(kind, n, 'tmp').to_s
      assert_equal File.join(@sandbox, 'share', 'python_tasks', "#{n}.py"), resolved
    end
    nested = @agent.resolve_path(kind, 'nested/deep_probe', 'project').to_s
    assert_equal File.join(@sandbox, 'python', 'tasks', 'nested', 'deep_probe.py'), nested

    # read + edit + rename + delete
    raw = tool('path_read', 'kind' => kind, 'path' => 'crud_probe',
                           'location' => 'tmp')
    content = Hash === raw ? raw['content'] : raw
    assert_equal PY_GOOD, content
    tool('path_rename', 'kind' => kind, 'path' => 'crud_probe',
                        'name' => 'crud_renamed')
    assert File.exist?(File.join(@sandbox, 'share', 'python_tasks', 'crud_renamed.py'))
    tool('path_delete', 'kind' => kind, 'path' => 'under_scored2')
    refute File.exist?(File.join(@sandbox, 'share', 'python_tasks', 'under_scored2.py'))
  end

  # 4. validate matrix.
  def test_python_task_validate_matrix
    kind = py_kind!
    py_seed('val_good')
    r = py_validate(kind, 'val_good')
    assert_equal true, r['ok']
    assert_equal [], r['reasons']

    py_seed('val_empty', "import scout\n\n\n")
    r = py_validate(kind, 'val_empty')
    assert_equal false, r['ok']
    assert r['reasons'].any? { |x| x =~ /scout\.task/ }

    py_seed('val_syntax', "def broken(:\n")
    r = py_validate(kind, 'val_syntax')
    assert_equal false, r['ok']
    assert r['reasons'].any? { |x| x =~ /invalid Python syntax/i }

    # invalid NAME: only reachable through a physical bad file
    bad = File.join(@sandbox, 'share', 'python_tasks', 'BadName.py')
    File.write(bad, PY_GOOD)
    r = py_validate(kind, 'BadName')
    assert_equal false, r['ok']
    assert r['reasons'].any? { |x| x =~ /invalid task name/i }
    File.delete(bad)

    # missing target
    r = py_validate(kind, 'val_missing')
    assert_equal false, r['ok']
    assert r['reasons'].any? { |x| x =~ /does not exist/ }

    # docstring convention is a WARNING at both locations, never an error
    nodoc_lines = ['import scout', '', 'def val_nodoc(x: int = 1) -> int:',
                   '    return x', '', 'scout.task(val_nodoc)', '']
    nodoc = nodoc_lines.join("\n")
    py_seed('val_nodoc', nodoc)
    py_seed('val_nodoc', nodoc, 'project')
    %w[tmp project].each do |loc|
      r = py_validate(kind, 'val_nodoc', loc)
      assert_equal true, r['ok'], "nodoc at #{loc}: #{r['reasons'].inspect}"
      assert r['warnings'].any? { |w| w =~ /module docstring/ }, "warning at #{loc}"
    end

    # validate is static: no __pycache__ beside any target
    assert Dir.glob(File.join(@sandbox, '**', '__pycache__')).empty?
  end

  # 5. smoke: registration + job construction, never execution.
  def test_python_task_smoke_constructs_job_without_executing
    kind = py_kind!
    marker = File.join(@sandbox, 'PY_SMOKE_CANARY')
    canary = PY_GOOD.sub('return f"hello {name}"',
                         "open('#{marker}', 'w').write('EXECUTED')\n    return f\"hello {name}\"")
    py_seed('smoke_canary', canary)

    r = smoke_result(kind: kind, path: 'smoke_canary')
    assert_equal true, r['ok']
    assert_equal 'construct', r['stage']
    assert_equal false, r['executed']
    assert_match(/SMOKE_OK stage=construct task=py_fixture/, r['stdout'])
    refute File.exist?(marker), 'task body must never run during smoke'
    assert Dir.glob(File.join(@sandbox, '**', '__pycache__')).empty?,
           'smoke must never leave a __pycache__'
  end

  # 6. smoke failures are clean ParameterExceptions naming the stage.
  def test_python_task_smoke_failures_raise_with_stage
    kind = py_kind!
    py_seed('smoke_noreg', "import scout\n\ndef f(x: int = 1) -> int:\n    return x\n")
    r = smoke_result(kind: kind, path: 'smoke_noreg')
    m = r['exception'].to_s + r['message'].to_s
    assert_match(/smoke: python_task .* failed at stage=register/, m)

    py_seed('smoke_bad', "def broken(:\n")
    r = smoke_result(kind: kind, path: 'smoke_bad')
    m = r['exception'].to_s + r['message'].to_s
    assert_match(/failed at stage=check: .*syntax/i, m)

    r = smoke_result(kind: kind, path: 'smoke_missing')
    m = r['exception'].to_s + r['message'].to_s
    assert_match(/failed at stage=check: .*does not exist/, m)
  end

  # 7. promote matrix: success, no-clobber, overwrite, failure intact.
  def test_python_task_promote_matrix
    kind = py_kind!
    src_root = File.join(@sandbox, 'share', 'python_tasks')
    dst_root = File.join(@sandbox, 'python', 'tasks')
    FileUtils.mkdir_p(src_root); FileUtils.mkdir_p(dst_root)

    py_seed('promo_a')
    r = promote(kind, 'promo_a')
    assert File.exist?(File.join(dst_root, 'promo_a.py')), 'promoted file present'
    refute File.exist?(File.join(src_root, 'promo_a.py')), 'draft moved away'

    py_seed('promo_b')
    File.write(File.join(dst_root, 'promo_b.py'), 'OCCUPIED')
    r = promote(kind, 'promo_b')
    assert_match(/exist/i, r['exception'].to_s)
    assert_equal PY_GOOD, File.read(File.join(src_root, 'promo_b.py')),
                 'refused promotion leaves the source intact'
    assert_equal 'OCCUPIED', File.read(File.join(dst_root, 'promo_b.py'))

    r = promote(kind, 'promo_b', overwrite: true)
    assert_equal PY_GOOD, File.read(File.join(dst_root, 'promo_b.py')),
                 'overwrite replaces the destination'

    # underscore-bearing name promotes with the same spelling
    py_seed('under_scored_promo')
    r = promote(kind, 'under_scored_promo')
    assert File.exist?(File.join(dst_root, 'under_scored_promo.py'))
  end

  # 8. containment negatives with outside-root canaries.
  def test_python_task_containment_rejects_outside_targets
    kind = py_kind!
    outside = Dir.mktmpdir('r11-py-containment-outside')
    canary = File.join(outside, 'canary.txt')
    File.write(canary, 'R11-PY-CANARY')
    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'python_tasks'))

    # The path tool wrapper returns raised ScoutExceptions as a JSON String
    # (see the smoke_result helper note), so denials are asserted on the
    # returned envelope rather than with assert_raise.
    r = write_draft(kind, '../escape', PY_GOOD)
    assert_match(/Path access denied by sandbox/, r.to_s, 'traversal write denied')
    r = promote(kind, '../../escape')
    assert_match(/Path access denied by sandbox|not allowed/, r.to_s, 'traversal promote denied')

    link = File.join(@sandbox, 'share', 'python_tasks', 'outside_link')
    File.symlink(outside, link)
    # resolve_path alone does not walk the tree (an intermediate symlink
    # component only realpaths during the authorize walk), so the denial is
    # asserted through the same tool wrapper as the traversal arms above.
    r = write_draft(kind, 'outside_link/canary', PY_GOOD)
    assert_match(/Path access denied by sandbox/, r.to_s, 'symlink escape write denied')
    r = promote(kind, 'outside_link/canary')
    assert_match(/Path access denied by sandbox/, r.to_s, 'symlink escape promote denied')

    assert_equal 'R11-PY-CANARY', File.read(canary), 'outside canary untouched'
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  # 8.16 README-vs-code lock: the registered kind set is exactly the six
  # kinds the `## Agent path kinds` README section documents, and the
  # run_test / run_probe custom operations are installed as model-facing tools.
  def test_registered_kinds_match_readme_documented_set
    documented = %w[task entity entity_property python_task test_file probe].sort
    registered = @agent.path_kind_registry.keys.sort
    assert_equal documented, registered,
                 'PATH_KINDS must match the kinds documented in README ## Agent path kinds'

    tf = ScoutCoder::PATH_KINDS.fetch('test_file')
    assert tf.fetch('operations').key?('run_test'),
           'test_file must register the run_test custom operation'
    assert !tf.fetch('capabilities', {}).key?('patch') || tf.fetch('capabilities').fetch('patch').equal?(false),
           'patch must stay off for test_file'
    assert @agent.other_options[:tools].key?('run_test'),
           'the run_test tool must be installed alongside the path tools'

    # Round 12: the probe kind — one root, promote-less, validate + run_probe.
    pb = ScoutCoder::PATH_KINDS.fetch('probe')
    assert_equal %w[tmp], pb.fetch('locations'),
                 'probe is a ONE-location kind (share/probes only)'
    assert pb.fetch('operations').key?('run_probe'),
           'probe must register the run_probe custom operation'
    assert_equal false, pb.fetch('capabilities').fetch('promote', false),
                 'probe must be promote-less'
    assert @agent.other_options[:tools].key?('run_probe'),
           'the run_probe tool must be installed alongside the path tools'
  end

  # =====================================================================
  # CamelCase entity-TYPE naming convention (decision artifact
  # reports/entity-case-convention-decision.md, item 6): the engine-facing
  # validate matrix for the `entity` and `entity_property` kinds. Runs in
  # a SANDBOXED kind copy (like every other validate test here) so the
  # real share/entities/ drafts never influence the collision arms.
  # =====================================================================

  # CamelCase names — acronym, acronym+digits, multi-word — validate clean
  # with NO warning, and the declared module matches the path unchanged
  # (constant_name passes CamelCase through; nothing is camelised).
  def test_entity_validate_accepts_camelcase_clean
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    write_draft(kind, 'TF', "module ::TF\n  extend Entity\nend\n")
    r = validate_result(kind, 'TF')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'TF', r['module']
    assert_empty r['warnings'], 'canonical CamelCase must validate with NO warning'

    write_draft(kind, 'TF2', "module TF2\n  extend Entity\nend\n")
    r = validate_result(kind, 'TF2')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'TF2', r['module']
    assert_empty r['warnings']

    write_draft(kind, 'DemoWidget', "module ::DemoWidget\n  extend Entity\nend\n")
    r = validate_result(kind, 'DemoWidget')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'DemoWidget', r['module']
    assert_empty r['warnings']
  end

  # Underscore CamelCase (Demo_Widget) is neither canonical nor legacy —
  # a hard validate error carrying the new message.
  def test_entity_validate_hard_rejects_underscore_camelcase
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    write_draft(kind, 'Demo_Widget', "module DemoWidget\n  extend Entity\nend\n")
    r = validate_result(kind, 'Demo_Widget')
    assert_equal false, r['ok']
    assert_match(/invalid entity name "Demo_Widget": expected CamelCase \[A-Z\]\[A-Za-z0-9\]*/,
                 r['reasons'].join(' '))
    # The module mismatch must NOT be reported on top: the name was
    # rejected before a module constant could be expected.
    refute r['reasons'].any? { |reason| reason.include?('top-level module must be') },
           'an invalid name must not also demand a module constant'
  end

  # Legacy snake drafts keep validating WITH the acceptance warning naming
  # both spellings, the virtual path stays unchanged, and the declared
  # module is the Rule-B constant.
  def test_entity_validate_accepts_legacy_snake_with_warning
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    write_draft(kind, 'demo_widget', "module DemoWidget\n  extend Entity\nend\n")
    r = validate_result(kind, 'demo_widget')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'DemoWidget', r['module'], 'legacy snake camelises by Rule B for the module rule'
    assert_equal 1, r['warnings'].length
    assert_include r['warnings'].first, "legacy snake_case entity name 'demo_widget'"
    assert_include r['warnings'].first, "module constant 'DemoWidget'"

    # A lowercase single-word name is the legacy branch too (NOT canonical),
    # so it warns rather than passing silently.
    write_draft(kind, 'tf', "module Tf\n  extend Entity\nend\n")
    r = validate_result(kind, 'tf')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 1, r['warnings'].length, 'lowercase name must take the legacy branch, not pass silently'

    # Digit-bearing legacy name: the declared module is the Rule-B constant
    # (constant_name), which is exactly what the real drafts declare.
    name = 'workflow_entity_probe_12_727a8b'
    write_draft(kind, name, "module ::WorkflowEntityProbe12727a8b\n  extend Entity\nend\n")
    r = validate_result(kind, name)
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'WorkflowEntityProbe12727a8b', r['module']
    assert_equal 1, r['warnings'].length
  end

  # A declared module that does not match constant_name of the path is an
  # error, for BOTH canonical and legacy paths.
  def test_entity_validate_rejects_module_mismatch_for_both_spellings
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    write_draft(kind, 'DemoWidget', "module ::Gateway\n  extend Entity\nend\n")
    r = validate_result(kind, 'DemoWidget')
    assert_equal false, r['ok']
    assert_match(/top-level module must be `DemoWidget` .* found `Gateway`/, r['reasons'].join(' '))

    write_draft(kind, 'demo_widget', "module ::Gateway\n  extend Entity\nend\n")
    r = validate_result(kind, 'demo_widget')
    assert_equal false, r['ok']
    assert_match(/top-level module must be `DemoWidget` .* found `Gateway`/, r['reasons'].join(' '))
  end

  # Constant collisions are HARD errors, both directions, both pair kinds:
  # snake+CamelCase, and two snake names whose Rule-B constants collapse.
  def test_entity_validate_constant_collisions_are_hard_errors
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    write_draft(kind, 'DemoWidget', "module DemoWidget\n  extend Entity\nend\n")
    write_draft(kind, 'demo_widget', "module DemoWidget\n  extend Entity\nend\n")
    r = validate_result(kind, 'demo_widget')
    assert_equal false, r['ok'], 'snake name colliding with a CamelCase sibling must hard-fail'
    assert_match(/constant collision: legacy snake_case entity name 'demo_widget' and CamelCase entity name 'DemoWidget' both map to module constant 'DemoWidget'/,
                 r['reasons'].join(' '))
    assert_equal 1, r['warnings'].length, 'the legacy acceptance warning still surfaces beside the error'

    r = validate_result(kind, 'DemoWidget')
    assert_equal false, r['ok'], 'the collision is an error from the CamelCase side too'
    assert_match(/entity name 'DemoWidget' collides with legacy snake_case entity name 'demo_widget'/,
                 r['reasons'].join(' '))
    assert_empty r['warnings']

    # Rule-B collapse between two snake names: a_b and a__b -> AB.
    write_draft(kind, 'a_b', "module AB\n  extend Entity\nend\n")
    write_draft(kind, 'a__b', "module AB\n  extend Entity\nend\n")
    r = validate_result(kind, 'a_b')
    assert_equal false, r['ok']
    assert_match(/legacy snake_case entity names 'a_b' and 'a__b' both camelise to module constant 'AB'/,
                 r['reasons'].join(' '))
    r = validate_result(kind, 'a__b')
    assert_equal false, r['ok']
    assert_match(/both camelise to module constant 'AB'/, r['reasons'].join(' '))
  end

  # entity_property kind: the ENTITY SEGMENT follows the same rules.
  def test_entity_property_validate_entity_segment_follows_case_rules
    confine_kind_root_to_sandbox!
    kind_e = sandbox_kind!('entity')
    kind_p = sandbox_kind!('entity_property')

    # CamelCase first segment: canonical, clean.
    write_draft(kind_p, 'TF/palette', "module TF\n  property :palette => :single do 'x' end\nend\n")
    r = validate_result(kind_p, 'TF/palette')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'TF', r['module']
    assert_empty r['warnings']

    write_draft(kind_p, 'DemoWidget/tag_palette',
                "module DemoWidget\n  property :tag_palette => :single do 'x' end\nend\n")
    r = validate_result(kind_p, 'DemoWidget/tag_palette')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'DemoWidget', r['module']
    assert_empty r['warnings']

    # Legacy snake first segment: accepted with the warning, module matched
    # via constant_name of the segment (Rule B).
    write_draft(kind_p, 'demo_widget/tag_palette',
                "module DemoWidget\n  property :tag_palette => :single do 'x' end\nend\n")
    r = validate_result(kind_p, 'demo_widget/tag_palette')
    assert_equal true, r['ok'], r['reasons'].inspect
    assert_equal 'DemoWidget', r['module']
    assert_equal 1, r['warnings'].length
    assert_include r['warnings'].first, "legacy snake_case entity name 'demo_widget'"

    # Underscore CamelCase first segment is a hard error.
    write_draft(kind_p, 'Demo_Widget/tag_palette',
                "module DemoWidget\n  property :tag_palette => :single do 'x' end\nend\n")
    r = validate_result(kind_p, 'Demo_Widget/tag_palette')
    assert_equal false, r['ok']
    assert_match(/invalid entity name "Demo_Widget"/, r['reasons'].join(' '))

    # The collision check also reads the sibling share/entities/ root.
    write_draft(kind_e, 'DemoWidget', "module DemoWidget\n  extend Entity\nend\n")
    write_draft(kind_p, 'demo_widget/other_prop',
                "module DemoWidget\n  property :other_prop do 'x' end\nend\n")
    r = validate_result(kind_p, 'demo_widget/other_prop')
    assert_equal false, r['ok'], 'property under a snake entity colliding with the CamelCase sibling must fail'
    assert_match(/constant collision/, r['reasons'].join(' '))
  end

  # The REAL checkout drafts (20 files: 18 legacy snake + TF + DemoWidget)
  # all validate — the convention change never broke the existing drafts.
  def test_real_checkout_entity_drafts_all_validate
    %w[TF DemoWidget].each do |camel|
      r = validate_result('entity', camel)
      assert_equal true, r['ok'], "#{camel}: #{r['reasons'].inspect}"
      assert_empty r['warnings'], "#{camel} must carry no warning"
    end
    Dir.glob(File.join(ROOT, 'share', 'entities', '*.rb')).sort.each do |file|
      virtual = File.basename(file, '.rb')
      camel = virtual =~ /\A[A-Z][A-Za-z0-9]*\z/
      r = validate_result('entity', virtual)
      assert_equal true, r['ok'], "#{virtual}: #{r['reasons'].inspect}"
      warn_count = (r['warnings'] || []).length
      if camel
        assert_equal 0, warn_count, "#{virtual} is canonical and must not warn"
      else
        assert_equal 1, warn_count, "#{virtual} is legacy and must carry exactly the acceptance warning"
        assert_include r['warnings'].first, 'legacy snake_case entity name'
      end
    end
  end
end

# =====================================================================
# Round 11 — python test tier (test_file 'python' location, .py dispatch)
# =====================================================================
class TestPathKindsPythonTestTier < TestPathKinds
  # Reuse the parent harness (sandbox, seeds, run_test_call) so the python
  # tier cases sit beside their Ruby counterparts; only the assertions are
  # new. The parent's tests re-run here unchanged, which is exactly the
  # Ruby-unchanged regression the round asked for.

  def test_python_test_file_scope_pass_and_fail_distinguishable
    kind = tf_kind!
    py_test_seed('ok_probe', PY_TEST_PASS)
    py_test_seed('bad_probe', PY_TEST_FAIL)

    r = run_test_call(kind, 'python_task/ok_probe', 'file', location: 'python')
    assert_equal 1, r['count']
    assert_equal true, r['ok']
    hit = r['results'].first
    assert_equal 'clean_pass', hit['exit_class']
    assert_equal true, hit['passed']
    assert_equal true, hit['ran']
    assert_match(/python3 -m unittest test_ok_probe/, hit['runner'].to_s)

    f = run_test_call(kind, 'python_task/bad_probe', 'file', location: 'python')
    assert_equal false, f['ok']
    bad = f['results'].first
    assert_equal 'assertion_failure', bad['exit_class']
    assert_equal false, bad['passed']
    assert_equal true, bad['ran'], 'a failing python test still RAN'
    assert_match(/AssertionError|assertEqual/, (bad['stdout'].to_s + bad['stderr'].to_s))
  end

  def test_python_test_directory_scope_runs_every_file
    kind = tf_kind!
    py_test_seed('d1', PY_TEST_PASS)
    py_test_seed('d2', PY_TEST_FAIL)
    r = run_test_call(kind, '.', 'directory', location: 'python')
    assert_equal 2, r['count']
    assert_equal false, r['ok']
    assert_equal %w[test_d1.py test_d2.py],
                 r['results'].collect { |x| File.basename(x['file']) }.sort
    refute Dir.exist?(File.join(@sandbox, 'python', 'test', '__pycache__')),
           'python runner must not create __pycache__ in the test tree'
  end

  def test_python_test_suite_scope_includes_python_location
    kind = tf_kind!
    tf_seed('rb_alpha', TF_PASS)
    py_test_seed('py_alpha', PY_TEST_PASS)
    r = run_test_call(kind, '.', 'suite')
    py = r['results'].find { |x| x['file'].end_with?('test_py_alpha.py') }
    assert py, 'suite scope must discover the python-location test'
    assert_equal true, py['passed']
    rb = r['results'].find { |x| x['file'].end_with?('rb_alpha.rb') }
    assert rb, 'suite scope keeps discovering the tmp-side Ruby test'
    assert_equal true, rb['passed']
    assert_equal true, r['ok']
  end

  def test_python_test_syntax_error_is_load_error_not_silent
    kind = tf_kind!
    py_test_seed('syntax_broken', "import unittest\n this is not python\n")
    r = run_test_call(kind, 'python_task/syntax_broken', 'file', location: 'python')
    hit = r['results'].first
    assert_equal 'load_error', hit['exit_class']
    assert_equal false, hit['passed']
    assert_equal false, hit['ran']
  end

  def test_python_test_other_tiers_rejected_at_python_location
    kind = tf_kind!
    e = assert_raise(ParameterException) do
      @agent.resolve_path('test_file', 'task/greet_user', 'python')
    end
    assert_match(/hosts only the python_task tier/, e.message)
  end

  def test_python_test_containment_denies_traversal_and_absolute
    kind = tf_kind!
    outside = Dir.mktmpdir('r11-pyt-containment')
    canary = File.join(outside, 'canary.txt')
    File.write(canary, 'R11-PYT-CANARY')

    r = write_draft(kind, '../escape', PY_GOOD)
    assert_match(/denied by sandbox|'..' is not allowed/, r.to_s)
    r = write_draft_at(kind, 'python_task/x', PY_GOOD, 'python')
    assert r['written'], 'python tier write lands in the python location'
    # A python test body at a RUBY tier/tmp is a plain write into that tier's
    # root — containment holds via the grammar/roots; what is denied at the
    # python location is foreign-tier addressing only when file-shaped.
    r = write_draft_at(kind, 'task/x', PY_GOOD, 'tmp')
    assert r['written'], 'tmp ruby tier holds .rb-named files regardless of body'
    e = assert_raise(ParameterException) do
      @agent.resolve_path('test_file', '/etc/passwd', 'python')
    end
    assert_match(/absolute|start with/, e.message)
    assert_equal 'R11-PYT-CANARY', File.read(canary), 'outside canary untouched'
  ensure
    FileUtils.rm_rf(outside) if outside
  end
end

# =====================================================================
# Round 12 — the `probe` path kind (unsandboxed ScoutCoder-only snippets)
# =====================================================================
# Contract under test (lib/ScoutCoder/path_kinds/probe.rb +
# lib/ScoutCoder/probe_support.rb + lib/ScoutCoder/tasks/probe_tools.rb):
#
#   * ONE location root share/probes/ ('tmp'), NO promote, NO smoke,
#     NO patch, validate (syntax-only, NEVER executes) plus ONE custom
#     operation run_probe (:full handler, authorization: :read).
#   * The run_probe operation, when `source` is supplied, owns the
#     write: save first (never reverted on failure), AST syntax-check,
#     then execute — reporting saved/syntax/execution as INDEPENDENT
#     outcomes.
#   * The child is a FRESH UNSANDBOXED Ruby process that preloads the
#     owning checkout's workflow.rb before loading the probe
#     (PATH_KIND_PROJECT_ROOT seam preserved).
#   * Failures are normalized: ParameterException or the structured
#     envelope, never a raw non-Scout exception.
#
# The motivating case (a probe reading a file OUTSIDE every Workspace
# sandbox grant in a fresh unsandboxed child) is pinned in
# share/test/integration/round12_outside_grant.rb — it needs the REAL
# engine checkout tree, so it cannot run inside the suite's sandbox
# harness here.
class TestPathKindsProbe < TestPathKinds
  PROBE_TMP_SUBDIR = 'probes'.freeze

  def probe_kind!
    confine_kind_root_to_sandbox!
    sandbox_kind!('probe')
  end

  def probe_run(kind, path, source: nil, timeout: nil)
    args = {'kind' => kind, 'path' => path}
    args['source'] = source unless source.nil?
    args['timeout_seconds'] = timeout unless timeout.nil?
    raw = tool('run_probe', args)
    if raw.is_a?(String) && raw.include?('"exception"')
      begin
        parsed = JSON.parse(raw)
        raise ParameterException, parsed['exception'] || parsed.inspect if parsed.key?('exception') && !parsed.key?('ok')
      rescue JSON::ParserError
        nil # fall through, return raw
      end
    end
    Hash === raw ? raw : JSON.parse(raw)
  end

  # canary helper: a probe source whose EXECUTION would write a file.
  def canary_source(canary, token)
    "File.write(#{canary.inspect}, #{token.inspect})"
  end

  # 1. write-with-source executes and reports the independent outcomes.
  def test_probe_write_with_source_executes_and_reports_independently
    kind = probe_kind!
    marker = File.join(@sandbox, 'probe-marker.txt')

    r = probe_run(kind, 'r12_write_run',
                  source: "puts 'R12-RAN'\nFile.write(#{marker.inspect}, 'x')\n")
    assert_equal true, r['saved'], 'source must be saved'
    assert_equal true, r['syntax_ok']
    assert_equal true, r['executed']
    assert_equal 'completed', r['execution']['exit_class']
    assert_match(/R12-RAN/, r['execution']['stdout'])
    assert File.exist?(marker), 'the probe body must have EXECUTED'
    assert File.file?(File.join(@sandbox, 'share', 'probes', 'r12_write_run.rb'))
  end

  # 2. runtime failure leaves the source saved and reports stderr/exception.
  def test_probe_runtime_failure_keeps_source_and_reports_exception
    kind = probe_kind!
    r = probe_run(kind, 'r12_boom',
                  source: "# boom probe\nraise 'R12-BOOM'\n")
    assert_equal true, r['saved'], 'source stays saved after a runtime failure'
    assert_equal true, r['syntax_ok']
    assert_equal 'raised', r['execution']['exit_class']
    refute_equal 0, r['execution']['exit_status']
    assert_match(/R12-BOOM/, r['execution']['stderr'])
    assert File.file?(File.join(@sandbox, 'share', 'probes', 'r12_boom.rb')),
                 'the saved probe file must NOT be reverted or deleted'
  end

  # 3. syntax failure saves but skips execution.
  def test_probe_syntax_failure_saves_but_skips_execution
    kind = probe_kind!
    canary = File.join(@sandbox, 'probe-syntax-canary.txt')

    r = probe_run(kind, 'r12_bad_syntax',
                  source: "File.write(#{canary.inspect}, 'x')\nq = 'unterminated\n")
    assert_equal true, r['saved'], 'a syntax failure still saves the source'
    assert_equal false, r['syntax_ok']
    assert_equal false, r['executed']
    assert_equal 'skipped_syntax_error', r['execution']['exit_class']
    assert_match(/syntax|unterminated/i, r['syntax_error'].to_s)
    assert !File.exist?(canary), 'an unparseable body must never execute'
    assert File.file?(File.join(@sandbox, 'share', 'probes', 'r12_bad_syntax.rb'))
  end

  # 4. validate NEVER executes — side-effect canary, valid AND invalid
  #    sources. This is the proof that validate is side-effect free.
  def test_probe_validate_never_executes_valid_or_invalid
    kind = probe_kind!
    canary = File.join(@sandbox, 'probe-validate-canary.txt')

    write_draft(kind, 'r12_canary', canary_source(canary, 'R12-VALIDATE'))
    r = validate_result(kind, 'r12_canary')
    assert_equal true, r['ok'], "valid probe must validate clean: #{r['reasons'].inspect}"
    assert !File.exist?(canary),
         'validate on a VALID probe must not execute it (canary absent)'

    write_draft(kind, 'r12_canary_bad',
                "#{canary_source(canary, 'R12-VALIDATE-BAD')}\nq = 'unterminated\n")
    r2 = validate_result(kind, 'r12_canary_bad')
    assert_equal false, r2['ok']
    assert !File.exist?(canary),
         'validate on an INVALID probe must not execute it (canary absent)'
  end

  # 5. re-execution of an unedited probe (repeatable observable effect):
  #    run twice through the run_probe operation, second call WITHOUT
  #    source, and observe the body twice.
  def test_probe_rerun_of_unedited_probe_repeats_effect
    kind = probe_kind!
    counter = File.join(@sandbox, 'probe-counter.txt')

    first = probe_run(kind, 'r12_repeat',
                      source: "n = (File.exist?(#{counter.inspect}) ? File.read(#{counter.inspect}).to_i : 0) + 1\nFile.write(#{counter.inspect}, n.to_s)\n")
    assert_equal 'completed', first['execution']['exit_class']

    second = probe_run(kind, 'r12_repeat') # path only: re-execute saved file
    assert_equal true, second['executed'], 'path-only run re-executes the existing probe'
    assert_equal 'completed', second['exit_class']
    assert_equal '2', File.read(counter),
                 'running the same probe twice must produce the effect twice'
  end

  # 6. timeout classification: a sleeping probe is TERMed and reported as
  #    'timeout' (process-group + TERM/grace/KILL discipline).
  def test_probe_timeout_classification
    kind = probe_kind!
    r = probe_run(kind, 'r12_sleep', source: "sleep 30\n", timeout: 1)
    assert_equal true, r['executed']
    assert_equal 'timeout', r['execution']['exit_class']
    assert r['execution']['duration_seconds'] < 15,
           "timeout must fire near the deadline (took #{r['execution']['duration_seconds']}s)"
  end

  # 7. timeout bounds are enforced BEFORE any write (normalize_timeout).
  #    The tool wrapper converts the hook's ParameterException into a JSON
  #    String ('exception'); probe_run re-raises it as ParameterException.
  def test_probe_timeout_bounds_rejected
    kind = probe_kind!
    canary = File.join(@sandbox, 'probe-bounds-canary.txt')
    e = assert_raise(ParameterException) do
      probe_run(kind, 'r12_bounds', source: canary_source(canary, 'x'), timeout: 0)
    end
    assert_match(/between 1 and 3600/, e.message)
    assert !File.exist?(File.join(@sandbox, 'share', 'probes', 'r12_bounds.rb')),
         'an out-of-range timeout must reject the call before saving'
  end

  # 8. the child preloads the owning checkout's workflow.rb — the probe
  #    can use Scout constants the moment it starts.
  def test_probe_child_preloads_owning_workflow
    kind = probe_kind!
    r = probe_run(kind, 'r12_workflow_probe',
                  source: "raise 'no ScoutCoder' unless defined?(ScoutCoder)\nputs \"WF=#{ScoutCoder.name}\"\n")
    assert_equal 'completed', r['execution']['exit_class'], r['execution']['stderr']
    assert_match(/WF=ScoutCoder/, r['execution']['stdout'])
    assert_match(/ScoutCoder\z/, r['execution']['workflow_loaded'].to_s)
  end

  # 9. the generic CRUD surface works and nothing auto-runs: path_write
  #    (outcome C, DC-1) NEVER executes the saved probe.
  def test_probe_generic_write_never_auto_runs
    kind = probe_kind!
    canary = File.join(@sandbox, 'probe-write-canary.txt')
    write_draft(kind, 'r12_nowrite', canary_source(canary, 'R12-AUTORUN'))
    assert File.file?(File.join(@sandbox, 'share', 'probes', 'r12_nowrite.rb'))
    assert !File.exist?(canary),
         'path_write must never auto-run the probe (outcome C: write ignores the operation table)'
  end

  # 10. promote-less: the engine installs no path_promote support for probe.
  def test_probe_kind_is_promote_less
    kind = probe_kind!
    assert_equal false, @agent.path_kind_definition(kind).fetch('capabilities').fetch('promote', false)
    raw = promote(kind, 'r12_write_run')
    assert raw.is_a?(String) || raw.is_a?(Hash)
    assert_match(/does not support promote|does not support operation/, raw.to_s)
  end

  # 11. nothing auto-loads share/probes: a fresh workflow load (the
  #     LiveWorkflow loader) never executes probe drafts.
  def test_nothing_auto_loads_share_probes
    canary = File.join(@sandbox, 'probes-auto-load-canary.txt')
    draft = File.join(@sandbox, 'share', 'probes', 'r12_autoload.rb')
    FileUtils.mkdir_p(File.dirname(draft))
    File.write(draft, canary_source(canary, 'R12-AUTOLOAD'))

    # A checkout needs a workflow.rb for the loader to require: copy the
    # real one plus the lib/ tree (LiveWorkflow loads it through the
    # checkout's own load path), then add the canary draft under
    # share/probes. Nothing may execute it.
    FileUtils.cp_r(File.join(ROOT, 'lib'), File.join(@sandbox, 'lib'))
    FileUtils.cp(File.join(ROOT, 'workflow.rb'), File.join(@sandbox, 'workflow.rb'))

    out, err, status = Open3.capture3(RbConfig.ruby, '-e',
      '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"',
      chdir: @sandbox)
    assert status.success?, "sandbox workflow load failed: #{err}"
    assert !File.exist?(canary),
         'a workflow load must never execute share/probes drafts (only the four LiveWorkflow subdirs load)'
  ensure
    FileUtils.rm_f(canary)
  end
end
