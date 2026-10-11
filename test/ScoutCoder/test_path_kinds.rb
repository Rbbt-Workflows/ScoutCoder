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
    File.join(ROOT, 'test', 'ScoutCoder', 'entity')
  ].freeze

  def setup
    @sandbox = Dir.mktmpdir('r7-path-kinds')
    @agent = LLM::Agent.new
    @agent.integrate_workflow_path_kinds(ScoutCoder)
    @saved_root = ScoutCoder::PATH_KIND_ROOT
    @real_before = snapshot_roots(REAL_ROOTS)
  end

  def teardown
    restore_kind_root
    FileUtils.rm_rf(@sandbox) if @sandbox
    assert_equal @real_before, snapshot_roots(REAL_ROOTS),
                 'real kind roots changed while a sandboxed test was running'
  end

  # ---------------------------------------------------------------- helpers

  # Swap ScoutCoder::PATH_KIND_ROOT to the sandbox so the production hook
  # lambdas derive their paired-test paths inside it.
  def confine_kind_root_to_sandbox!
    swap_kind_root!(@sandbox)
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
      'tmp' => File.join(@sandbox, 'share', KIND_TMP_SUBDIR[kind]),
      'project' => File.join(@sandbox, 'lib', 'ScoutCoder', 'entity')
    }
    copy.delete('promotion_post_move') if drop_hook
    probe_kind = "#{kind}_sandbox_probe"
    @agent.register_path_kind(probe_kind, copy)
    probe_kind
  end

  KIND_TMP_SUBDIR = {
    'entity' => 'entities',
    'entity_property' => 'entity_properties'
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

  def promote(kind, path, overwrite: nil)
    args = { 'kind' => kind, 'path' => path }
    args['overwrite'] = overwrite unless overwrite.nil?
    tool('path_promote', args)
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

  def test_entity_hook_moves_paired_test_and_nothing_else
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    name = "hooktest_#{SecureRandom.hex(4)}"
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity', "#{name}.rb")
    proj_paired = File.join(@sandbox, 'test', 'ScoutCoder', 'entity', "test_#{name}.rb")
    FileUtils.mkdir_p(File.dirname(tmp_paired))
    File.write(tmp_paired, "# paired entity test #{name}\n")

    # Decoration inside the sandbox that must NOT move.
    deco = File.join(@sandbox, 'share', 'test', 'entity', "hooktest_other_#{SecureRandom.hex(3)}.rb")
    File.write(deco, "# decoration\n")

    write_draft(kind, "#{name}.rb", entity_draft(name))
    before = snapshot_tree(@sandbox)

    r = promote(kind, "#{name}.rb")

    assert_equal true, r['promoted']
    assert_equal 'ok', r['post_move']
    assert_equal proj_paired, r['test_file_moved']

    after = snapshot_tree(@sandbox)
    added = after.keys - before.keys
    removed = before.keys - after.keys
    expected_added = [
      "lib/ScoutCoder/entity/#{name}.rb",
      "test/ScoutCoder/entity/test_#{name}.rb"
    ]
    expected_removed = [
      "share/entities/#{name}.rb",
      "share/test/entity/#{name}.rb"
    ]
    assert_equal expected_added.sort, added.sort,
                 "promotion wrote more than src/dst + paired test: #{added - expected_added}"
    assert_equal expected_removed.sort, removed.sort,
                 "promotion removed more than src + tmp paired test: #{removed - expected_removed}"
    assert_equal '# paired entity test ' + name + "\n", File.read(proj_paired),
                 'paired test content must be byte-identical after relocation'
    assert File.file?(deco), 'unrelated paired test must not move'
  end

  def test_property_hook_moves_paired_test_and_nothing_else
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity_property')
    entity = "hooktest_ent_#{SecureRandom.hex(3)}"
    property = 'hooklabel'
    vpath = "#{entity}/#{property}.rb"
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity_property', entity, "#{entity}.#{property}.rb")
    proj_paired = File.join(@sandbox, 'test', 'ScoutCoder', 'entity', "test_#{entity}_#{property}.rb")
    FileUtils.mkdir_p(File.dirname(tmp_paired))
    File.write(tmp_paired, "# paired property test #{entity}.#{property}\n")

    write_draft(kind, vpath, property_draft(entity, property))
    before = snapshot_tree(@sandbox)

    r = promote(kind, vpath)

    assert_equal true, r['promoted']
    assert_equal 'ok', r['post_move']
    assert_equal proj_paired, r['test_file_moved']

    after = snapshot_tree(@sandbox)
    added = after.keys - before.keys
    removed = before.keys - after.keys
    expected_added = [
      "lib/ScoutCoder/entity/#{entity}/#{property}.rb",
      "test/ScoutCoder/entity/test_#{entity}_#{property}.rb"
    ]
    expected_removed = [
      "share/entity_properties/#{entity}/#{property}.rb",
      "share/test/entity_property/#{entity}/#{entity}.#{property}.rb"
    ]
    assert_equal expected_added.sort, added.sort,
                 "promotion wrote more than src/dst + paired test: #{added - expected_added}"
    assert_equal expected_removed.sort, removed.sort,
                 "promotion removed more than src + tmp paired test: #{removed - expected_removed}"
    assert_equal "# paired property test #{entity}.#{property}\n", File.read(proj_paired)
  end

  def test_hook_creates_missing_destination_directories
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    name = "hooktest_mkdir_#{SecureRandom.hex(3)}"
    proj_dir = File.join(@sandbox, 'test', 'ScoutCoder', 'entity')
    refute File.directory?(proj_dir), 'precondition: destination dir absent'

    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'test', 'entity'))
    File.write(File.join(@sandbox, 'share', 'test', 'entity', "#{name}.rb"), "# paired #{name}\n")
    write_draft(kind, "#{name}.rb", entity_draft(name))

    r = promote(kind, "#{name}.rb")

    assert_equal 'ok', r['post_move']
    assert File.directory?(proj_dir), 'hook must mkdir_p the flattened test dir'
    assert File.file?(File.join(proj_dir, "test_#{name}.rb"))
  end

  def test_hook_is_noop_without_paired_test_and_creates_no_directories
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    name = "hooktest_notest_#{SecureRandom.hex(3)}"
    proj_dir = File.join(@sandbox, 'test', 'ScoutCoder', 'entity')

    write_draft(kind, "#{name}.rb", entity_draft(name))
    r = promote(kind, "#{name}.rb")

    assert_equal 'ok', r['post_move']
    assert_nil r['test_file_moved']
    refute File.directory?(proj_dir),
           'hook must not create the paired-test tree when there is no paired test'
  end

  def test_hook_skips_with_reason_when_destination_exists_without_overwrite
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    name = "hooktest_skip_#{SecureRandom.hex(3)}"
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity', "#{name}.rb")
    proj_paired = File.join(@sandbox, 'test', 'ScoutCoder', 'entity', "test_#{name}.rb")

    FileUtils.mkdir_p(File.dirname(tmp_paired))
    FileUtils.mkdir_p(File.dirname(proj_paired))
    File.write(tmp_paired, "# tmp paired #{name}\n")
    File.write(proj_paired, "# pre-existing promoted test\n")

    write_draft(kind, "#{name}.rb", entity_draft(name))
    r = promote(kind, "#{name}.rb")

    assert_equal 'skipped', r['post_move']
    assert_match(/paired test already exists: #{Regexp.escape(proj_paired)}/, r['reason'].to_s)
    assert File.file?(tmp_paired), 'tmp paired test must stay in place on skip'
    assert_equal '# pre-existing promoted test', File.read(proj_paired).strip,
                 'existing promoted test must not be clobbered without overwrite'
    assert File.file?(File.join(@sandbox, 'lib', 'ScoutCoder', 'entity', "#{name}.rb")),
           'the engine move itself still completed'
  end

  def test_hook_overwrite_true_relocates_over_existing_destination
    confine_kind_root_to_sandbox!
    kind = sandbox_kind!('entity')
    name = "hooktest_ow_#{SecureRandom.hex(3)}"
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity', "#{name}.rb")
    proj_paired = File.join(@sandbox, 'test', 'ScoutCoder', 'entity', "test_#{name}.rb")

    FileUtils.mkdir_p(File.dirname(tmp_paired))
    FileUtils.mkdir_p(File.dirname(proj_paired))
    File.write(tmp_paired, "# tmp paired #{name} v2\n")
    File.write(proj_paired, "# stale promoted test\n")

    write_draft(kind, "#{name}.rb", entity_draft(name))
    r = promote(kind, "#{name}.rb", overwrite: true)

    assert_equal 'ok', r['post_move']
    assert_equal proj_paired, r['test_file_moved']
    refute File.exist?(tmp_paired)
    assert_equal "# tmp paired #{name} v2\n", File.read(proj_paired)
  end

  # -------------------------------------------------------- trust boundary

  # What this proves, stated honestly: with promotion_post_move REMOVED from
  # the (otherwise identical) kind definition, a promotion moves ONLY the
  # primary source to the primary destination and leaves the paired test
  # untouched; and the engine's own authorization set (the kind roots) does
  # NOT contain the paired-test destination -- path_authorize! DENIES it.
  # The paired-test relocation is therefore performed solely by the
  # trusted-plugin hook, never by the engine-authorized endpoints.
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

    write_draft(kind, "#{name}.rb", entity_draft(name))
    r = promote(kind, "#{name}.rb")

    assert_equal true, r['promoted']
    refute r.key?('post_move'), 'hookless control arm must report no hook result'
    assert File.file?(dst)
    refute File.exist?(src)
    assert File.file?(tmp_paired), 'engine alone must leave the paired test in place'
    assert_equal "# paired sentinel #{name}\n", File.read(tmp_paired)
    refute File.exist?(proj_paired), 'engine alone must not create the promoted paired test'

    # Engine endpoint authorization: primary destination allowed, paired-test
    # destination DENIED (outside the kind roots).
    assert_nothing_raised do
      @agent.path_authorize!(kind, dst, 'project', mode: :write)
    end
    assert_raise(ParameterException) do
      @agent.path_authorize!(kind, proj_paired, 'project', mode: :write)
    end
  end

  # Same boundary for the entity_property kind, exercised through the hook
  # contract itself: a direct hook invocation with the engine's own
  # hook_args shape performs exactly one mv and reports it.
  def test_property_hook_direct_invocation_moves_exactly_one_file
    confine_kind_root_to_sandbox!
    entity = "hooktest_direct_#{SecureRandom.hex(3)}"
    property = 'hooklabel'
    tmp_paired = File.join(@sandbox, 'share', 'test', 'entity_property', entity, "#{entity}.#{property}.rb")
    proj_paired = File.join(@sandbox, 'test', 'ScoutCoder', 'entity', "test_#{entity}_#{property}.rb")
    FileUtils.mkdir_p(File.dirname(tmp_paired))
    File.write(tmp_paired, "# direct #{entity}\n")

    hook = ScoutCoder::PATH_KINDS['entity_property']['promotion_post_move']
    before = snapshot_tree(@sandbox)
    r = hook.call(@agent, "#{entity}/#{property}.rb", 'tmp',
                  'promotion_destination' => { 'location' => 'project', 'path' => "#{entity}/#{property}.rb" },
                  'promotion_target' => File.join(@sandbox, 'lib', 'ScoutCoder', 'entity', "#{entity}/#{property}.rb"),
                  'promotion_source_target' => File.join(@sandbox, 'share', 'entity_properties', "#{entity}/#{property}.rb"),
                  'overwrite' => false)

    assert_equal 'ok', r['post_move']
    assert_equal proj_paired, r['test_file_moved']
    after = snapshot_tree(@sandbox)
    assert_equal ["test/ScoutCoder/entity/test_#{entity}_#{property}.rb"], after.keys - before.keys,
                 'direct hook invocation must add exactly the relocated paired test'
    assert_equal ["share/test/entity_property/#{entity}/#{entity}.#{property}.rb"], before.keys - after.keys,
                 'direct hook invocation must remove exactly the tmp paired test'
  end

  # --------------------------------------------------- loader ordering

  def test_property_before_entity_load_fails_loudly_in_fresh_process
    confine_kind_root_to_sandbox!
    kind_entity = sandbox_kind!('entity')
    kind_property = sandbox_kind!('entity_property')
    entity = "hooktest_order_#{SecureRandom.hex(3)}"
    property = 'label'

    write_draft(kind_entity, "#{entity}.rb", entity_draft(entity))
    write_draft(kind_property, "#{entity}/#{property}.rb", property_draft(entity, property))
    promote(kind_entity, "#{entity}.rb")
    promote(kind_property, "#{entity}/#{property}.rb")

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

    write_draft(kind_entity, "#{entity}.rb", entity_draft(entity))
    write_draft(kind_property, "#{entity}/#{property}.rb", property_draft(entity, property))
    promote(kind_entity, "#{entity}.rb")
    promote(kind_property, "#{entity}/#{property}.rb")

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
end
