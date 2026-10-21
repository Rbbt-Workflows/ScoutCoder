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
    File.join(ROOT, 'test', 'ScoutCoder')
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
      'project' => Path.setup(File.join(@sandbox,
                                       kind == 'test_file' ? 'test' : 'lib',
                                       kind == 'test_file' ? 'ScoutCoder' : 'ScoutCoder/entity'))
    }
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
    'test_file' => 'test'
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

    # Engine endpoint authorization: the primary destination is inside the
    # sandbox grant (CWD); the paired-test destination is also inside that
    # grant (engine 4680bd9 authorizes against Dir.pwd, not the kind roots),
    # while anything OUTSIDE the sandbox grant is denied. The kind-roots
    # DENIAL premise is a pre-drift expectation; see the test comment.
    assert_nothing_raised do
      @agent.path_authorize!(kind, dst, 'project', mode: :write)
    end
    assert_nothing_raised do
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

  def tf_kind!
    confine_kind_root_to_sandbox!
    sandbox_kind!('test_file')
  end

  def tf_seed(name, source, tier = 'task')
    dir = File.join(@sandbox, 'share', 'test', tier)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.rb"), source)
  end

  def run_test_call(kind, path, scope, timeout: nil)
    args = { 'kind' => kind, 'path' => path, 'scope' => scope }
    args['timeout_seconds'] = timeout if timeout
    raw = tool('run_test', args)
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
    assert_equal %w[tmp project], defn.fetch('locations')
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
  end

  # 3. list round-trips virtual spellings on the project side.
  def test_test_file_list_round_trips_virtual_paths
    confine_kind_root_to_sandbox!
    proj = File.join(@sandbox, 'test', 'ScoutCoder')
    %w[tasks/greet_user.rb entity/test_demo.rb entity/e/test_p.rb
       integration/test_rt.rb helper/test_helper_tools.rb].each do |rel|
      FileUtils.mkdir_p(File.dirname(File.join(proj, rel)))
      File.write(File.join(proj, rel), "# fixture\n")
    end

    listed = @agent.path_list('kind' => 'test_file', 'location' => 'project')
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
  def test_test_file_list_honors_prefixes
    confine_kind_root_to_sandbox!
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

    list = ->(p, loc) { @agent.path_list('kind' => 'test_file', 'path' => p, 'location' => loc) }

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
        phys = @agent.resolve_path('test_file', v, loc).to_s
        assert File.file?(phys), "[#{loc}] #{v} must resolve to an existing file"
        assert phys.start_with?(root), "[#{loc}] #{v} resolved outside root: #{phys}"
      end
    end
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
    assert r['results'].all? { |x| x['ran'] }, 'both files must be reported'
  end

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

    empty = Dir.mktmpdir('r9-empty-suite')
    Dir.chdir(empty)
    rr = run_test_call(kind, '.', 'suite')
    Dir.chdir(@sandbox)
    assert_match(/no test files found|no test directories found/, rr['exception'].to_s)
    FileUtils.rm_rf(empty)
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
    %w[task entity entity_property].each do |k|
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

  # 8.16 README-vs-code lock: the registered kind set is exactly the four
  # kinds the `## Agent path kinds` README section documents, and the
  # run_test custom operation is installed as the model-facing tool.
  def test_registered_kinds_match_readme_documented_set
    documented = %w[task entity entity_property test_file].sort
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
  end
end
