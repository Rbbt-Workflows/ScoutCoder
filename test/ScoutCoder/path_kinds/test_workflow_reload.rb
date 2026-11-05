require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# ---------------------------------------------------------------------------
# Unit tests for the workflow-level reload helper
# lib/ScoutCoder/path_kinds/workflow_reload.rb (reload build, step 2).
#
# The contract under test was pinned by the step-1 evidence probe
# (tmp/notes/reload-probe.md, probe source
# tmp/reload_probe/probe_source_take3.rb): purge composition (every .rb
# feature realpath'd under the realpath'd checkout root, entrypoint
# included when cached), realpath-on-both-sides normalization,
# require_workflow re-entry, module identity, and memo non-interference.
#
# Every test builds a DISPOSABLE fixture workflow checkout (workflow.rb +
# lib/ helper with a sentinel effect + share/) under Dir.mktmpdir; no real
# tree is ever purged except the deliberate real-checkout reload in the
# memo-survival test, whose effect is asserted to be identity-preserving.
#
# Step 3 (promotion wiring) tests live in the PROMOTION section below: the
# shared PROMOTION_POST_MOVE hook fires the reload after the engine's
# move, never on refusal, and never writes files. They go through a real
# LLM::Agent promote (a sandboxed copy of the production `task` kind whose
# registered hook is the production lambda object, equal?-asserted).
# ---------------------------------------------------------------------------
class TestWorkflowReload < Test::Unit::TestCase
  ROOT = File.expand_path('../../..', __dir__)
  WR = ScoutCoder::WorkflowReload

  def setup
    @sandbox = Dir.mktmpdir('wr-step2')
    @fixture = File.join(@sandbox, 'FixtureWF')
    build_fixture(@fixture)
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # ------------------------------------------------------------- fixture

  # Minimal workflow checkout: workflow.rb (require_relative to the lib
  # file), lib/FixtureWF/helper.rb with a SENTINEL effect (a line appended
  # to load_counter at every execution of the file), and a share/
  # directory. No in-memory constant: the sentinel must be observable
  # cross-process and free of already-initialized warnings.
  def build_fixture(root)
    FileUtils.mkdir_p(File.join(root, 'lib', 'FixtureWF'))
    FileUtils.mkdir_p(File.join(root, 'share'))
    File.write(File.join(root, 'lib', 'FixtureWF', 'helper.rb'), <<~RUBY)
      module FixtureWF
        File.open(File.expand_path('../../load_counter', __dir__), 'a') do |f|
          f.puts "load pid=\#{Process.pid}"
        end
      end
    RUBY
    File.write(File.join(root, 'workflow.rb'), <<~RUBY)
      require 'scout'
      module FixtureWF
        extend Workflow
      end
      require_relative 'lib/FixtureWF/helper'
    RUBY
  end

  def counter_path
    File.join(@fixture, 'load_counter')
  end

  def load_count
    File.exist?(counter_path) ? File.readlines(counter_path).size : 0
  end

  def load_workflow(root = @fixture)
    Workflow.require_workflow(File.join(root, 'workflow.rb'), silent: true)
  end

  def feature_spelling(root, rel)
    $LOADED_FEATURES.find { |f| File.expand_path(f.to_s) == File.join(File.realpath(root), rel) }
  end

  # A relative require from inside the fixture produces the canonical
  # absolute spelling (Ruby expands before caching), so a genuinely
  # differently-spelled cache entry must be crafted: push an
  # alias-spelled string into $LOADED_FEATURES directly, mirroring what a
  # differently-mounted process would have cached. Restored in ensure.
  def with_alias_feature(alias_path)
    raise "alias feature #{alias_path} must not already be cached" if $LOADED_FEATURES.include?(alias_path)
    $LOADED_FEATURES << alias_path
    begin
      yield alias_path
    ensure
      $LOADED_FEATURES.delete(alias_path)
    end
  end

  # --------------------------------------------------- (a) purge + reload

  # (a) Behavioral: the lib sentinel re-executes after purge+reload
  # (delta >= 1), nothing re-executes before it (the require_relative
  # cache holds), and the workflow module identity survives.
  def test_sentinel_reexecutes_after_purge_and_reload
    first = load_workflow
    assert_equal 1, load_count, 'initial load fires the sentinel once'
    baseline = load_count

    report = WR.reload_workflow!(root: @fixture)

    assert_equal true, report['ok'], report.inspect
    assert_operator load_count - baseline, :>=, 1,
                    'sentinel must re-execute (delta >= 1) after purge+reload'
    assert_includes report['purged'],
                    feature_spelling(@fixture, 'lib/FixtureWF/helper.rb'),
                    'the cached lib feature must be reported purged'
    assert report['workflow'].equal?(first),
           're-evaluation must return the SAME workflow module object'
    assert_equal 're-evaluated', report['reload'],
                 'entrypoint was not itself a feature entry here (require_workflow load)'
  end

  # (a, control arm) update:true alone does NOT re-fire require_relative:
  # the staleness the mechanism exists to fix.
  def test_update_alone_does_not_reexecute_lib_file
    load_workflow
    baseline = load_count
    Workflow.require_workflow(File.join(@fixture, 'workflow.rb'), silent: true, update: true)
    assert_equal baseline, load_count,
                 'update:true without purge must keep the cached lib file (control arm)'
  end

  # (a, fail loud) a root without workflow.rb and a missing root are
  # ParameterExceptions (this helper is only for real workflow checkouts).
  def test_missing_root_and_missing_entrypoint_fail_loudly
    empty = File.join(@sandbox, 'not_a_checkout')
    FileUtils.mkdir_p(empty)
    e = assert_raise(ParameterException) { WR.reload_workflow!(root: empty) }
    assert_match(/no workflow\.rb at the checkout root/, e.message)

    assert_raise(ParameterException) { WR.reload_workflow!(root: File.join(@sandbox, 'nope')) }
    assert_raise(ParameterException) { WR.reload_workflow!(root: nil) }
    assert_raise(ParameterException) { WR.reload_workflow!(root: '') }
  end

  # ------------------------------------------------- (b) entrypoint purge

  # (b) A child-style cached entrypoint (`require './workflow'`) is purged
  # too, and the report records the 'required' reload path.
  def test_cached_entrypoint_is_also_purged
    entry = File.join(File.realpath(@fixture), 'workflow.rb')
    with_alias_feature(entry) do
      report = WR.reload_workflow!(root: @fixture)
      assert_includes report['purged'], entry,
                      'a cached workflow.rb entry must be purged with the rest'
      assert_equal 'required', report['reload'],
                   "when the entrypoint itself was cached, reload goes through require (got #{report['reload'].inspect})"
      assert_equal true, report['ok']
    end
  end

  # ---------------------------------------------------- (c) alias spelling

  # (c) A differently-spelled (symlink alias) feature entry matches the
  # purge rule: realpath on both sides collapses the spellings, while
  # expand_path alone would not.
  def test_alias_spelled_feature_is_matched_and_purged
    alias_link = File.join(@sandbox, 'alias_link')
    File.symlink(@fixture, alias_link)
    aliased = File.join(alias_link, 'lib', 'FixtureWF', 'helper.rb')

    # The rule itself: realpath matches, expand_path alone does not.
    root_real = File.realpath(@fixture)
    assert WR.feature_under?(aliased, root_real),
           'realpath normalization must match the alias spelling'
    aliased_expanded = File.expand_path(aliased)
    refute (aliased_expanded == root_real || aliased_expanded.start_with?(root_real + File::SEPARATOR)),
           'control: expand_path alone must NOT match the alias spelling'

    # The purge removes an alias-spelled cache entry (crafted entry; Ruby
    # itself canonicalizes alias requires, so a hand-crafted entry is the
    # only way to pin this).
    with_alias_feature(aliased) do
      report = WR.reload_workflow!(root: @fixture)
      assert_includes report['purged'], aliased,
                      'alias-spelled entry must be purged (as spelled)'
    end
  end

  # (c, alternate root spelling) reloading through the alias root purges
  # the canonically-spelled features (root normalization collapses).
  def test_reload_through_alias_root_purges_canonical_features
    alias_link = File.join(@sandbox, 'root_alias')
    File.symlink(@fixture, alias_link)
    load_workflow

    report = WR.reload_workflow!(root: alias_link)

    assert_equal File.realpath(@fixture), report['root'],
                 'the report must carry the realpath root, not the alias spelling'
    assert_includes report['purged'], feature_spelling(@fixture, 'lib/FixtureWF/helper.rb')
    assert_equal true, report['ok']
  end

  # ----------------------------------------------- (d) idempotence / no-op

  # (d) Double reload is safe and each reload re-executes the sentinel.
  # NOTE (observed behavior, not a defect): a reload RE-CACHES the purged
  # features — the re-evaluated workflow.rb fires its require_relative
  # lines again — so a second reload purges them again. Idempotence means
  # "safe and correct to call repeatedly", not "empty purge list".
  def test_double_reload_and_noop_reload_are_safe
    load_workflow
    helper = feature_spelling(@fixture, 'lib/FixtureWF/helper.rb')

    first = WR.reload_workflow!(root: @fixture)
    assert_equal true, first['ok']
    assert_includes first['purged'], helper

    second = WR.reload_workflow!(root: @fixture)
    assert_equal true, second['ok'], 'second reload must not raise'
    assert_includes second['purged'], helper,
                    'the re-cached lib feature is purged again on the second reload'
    assert_equal 're-evaluated', second['reload']
    assert_operator load_count, :>=, 3, 'each reload re-executed the sentinel'

    # No cached features at all (a root never loaded): the purge list IS []
    # there and the reload still succeeds (the sentinel fires once).
    fresh = File.join(@sandbox, 'FreshWF')
    build_fixture(fresh)
    report = WR.reload_workflow!(root: fresh)
    assert_equal true, report['ok']
    assert_equal [], report['purged'], 'nothing cached under a never-loaded root'
    assert_equal 1, File.readlines(File.join(fresh, 'load_counter')).size
  end

  # ------------------------------------------------ (e) framework untouched

  # (e) The fixture purge never touches framework or ScoutCoder features:
  # ScoutCoder/lib and scout-gear feature entries stay cached (the
  # framework here is loaded from /bulk/mvazque2/git checkouts, absolute
  # spellings — see the step-1 probe for the spelling survey).
  def test_framework_features_untouched
    load_workflow
    scout_feature = $LOADED_FEATURES.find { |f| f.end_with?('ScoutCoder/path_kinds/support.rb') }
    assert scout_feature, 'ScoutCoder support feature must be loaded by the harness'
    # Spelling-proof gear anchor: require_workflow is redefined by
    # scout-ai (lib/scout/llm/agent/workflow.rb) when loaded, so its
    # source_location is NOT the gear file; anchor on the loaded gear
    # feature itself (any spelling — dev checkout or gem), which always
    # ends scout/workflow.rb and contains the Workflow module.
    gear_feature = $LOADED_FEATURES.find { |f| f.end_with?('scout-gear/lib/scout/workflow.rb') } ||
                   $LOADED_FEATURES.find { |f| f =~ %r{gems/scout-gear[^/]*/lib/scout/workflow\.rb$} } ||
                   $LOADED_FEATURES.find { |f| f.end_with?('scout-gear/lib/scout/workflow.rb'.sub('scout-gear/', '')) && f.include?('scout-gear') }
    assert gear_feature, 'scout-gear workflow feature must be loaded by the harness'

    WR.reload_workflow!(root: @fixture)

    assert $LOADED_FEATURES.include?(scout_feature),
           'ScoutCoder features must survive a fixture-root purge'
    assert $LOADED_FEATURES.include?(gear_feature),
           'scout-gear framework features must survive the purge'
    # The dry-run twin agrees: nothing under the fixture root matches the
    # ScoutCoder feature, and the ScoutCoder feature does match its root.
    refute_includes WR.features_under(@fixture), scout_feature
    assert_includes WR.features_under(ROOT), scout_feature
  end

  # ------------------------------------------------------ (f) memo survival

  # (f) The @@target_workflow memo (ScoutCoder.target_workflow) survives a
  # reload and keeps pointing at the SAME module object — reloaded
  # definitions land on the memoized module, so the memo is never cleared.
  def test_target_workflow_memo_survives_reload_untouched
    load_workflow(@fixture)
    before = ScoutCoder.target_workflow
    refute_nil before, 'harness must have resolved the real workflow first'

    # Reload the REAL ScoutCoder checkout through the helper. This purges
    # the harness's own ScoutCoder features and re-evaluates workflow.rb —
    # the actual production scenario — and must still return the same
    # module object with the memo intact.
    report = WR.reload_workflow!(root: ROOT)

    assert_equal true, report['ok']
    after = ScoutCoder.target_workflow
    assert after.equal?(before),
           'the memo must keep pointing at the SAME workflow object after reload'
    assert report['workflow'].equal?(before),
           'reload_workflow! must return the memoized module object itself'
    # The reloaded tree re-registered its kinds (PATH_KINDS intact after a
    # full purge+reload of the real checkout).
    assert ScoutCoder::PATH_KINDS.is_a?(Hash) && ScoutCoder::PATH_KINDS.key?('task')
  end

  # (f, fixture arm) module identity for the fixture workflow when the
  # entrypoint was itself cached (the 'required' path): still one object.
  def test_module_identity_holds_through_required_path
    entry = File.join(File.realpath(@fixture), 'workflow.rb')
    first = load_workflow
    with_alias_feature(entry) do
      report = WR.reload_workflow!(root: @fixture)
      assert_equal 'required', report['reload']
      assert report['workflow'].equal?(first),
             'module identity must hold on the require path as well'
    end
  end

  # ------------------------------------------------- PROMOTION WIRING (step 3)
  #
  # These tests exercise the SHARED hook ScoutCoder::WorkflowReload::
  # PROMOTION_POST_MOVE through a real engine promote on a sandboxed copy
  # of the production `task` kind definition (roots inside Dir.mktmpdir),
  # exactly like test/ScoutCoder/test_path_kinds.rb: the copy carries the
  # production lambda by reference, so what runs IS the shipped hook.
  # Fixture layout: a task DRAFT under <root>/share/tasks/, the owning
  # checkout under <root>/ with lib/<workflow>/tasks/, so the promote's
  # destination is inside a real (disposable) workflow checkout.

  # Resolve the hook at CALL time: the memo test reloads the real
  # ScoutCoder checkout mid-suite, which re-creates the PROMOTION_POST_MOVE
  # lambda (constants re-assign on Kernel#load re-evaluation), so a
  # class-load-time captured object would no longer be identical to the
  # one the (reloaded) production definition carries.
  def hook
    ScoutCoder::WorkflowReload::PROMOTION_POST_MOVE
  end

  def hook_sandbox
    sandbox = Dir.mktmpdir('wr-step3')
    root = File.join(sandbox, 'HookWF')
    FileUtils.mkdir_p(File.join(root, 'share', 'tasks'))
    FileUtils.mkdir_p(File.join(root, 'lib', 'HookWF', 'tasks'))
    File.write(File.join(root, 'workflow.rb'), <<~RUBY)
      require 'scout'
      module HookWF
        extend Workflow
      end
      File.open(File.expand_path('hook_counter', __dir__), 'a') { |f| f.puts "eval" }
    RUBY
    draft = File.join(root, 'share', 'tasks', 'hooked.rb')
    File.write(draft, "# HookWF task draft\nmodule HookWF\nend\n")
    [sandbox, root, draft]
  end

  # Production task-kind definition whose ROOTS point into the sandbox.
  # Requires the real path_kinds tree (loaded by test_helper via
  # workflow.rb), mirroring test_path_kinds.rb's copy pattern: no extra
  # requires — the harness's `require '../workflow'` already loads
  # scout-ai and the LLM namespace.
  def hooked_task_kind(sandbox)
    # Shallow copy with dup'd Hash values — the Marshal trick used elsewhere
    # cannot survive a Proc entry (no _dump_data); the engine itself
    # deep-copies what it needs at registration. The hook keeps production
    # identity (equal?-asserted by the caller).
    copy = {}
    ScoutCoder::PATH_KINDS['task'].each { |k, v| copy[k] = v.is_a?(Hash) ? v.dup : v }
    # Route both locations of the sandboxed copy at the sandbox fixture:
    # the draft lives at share/tasks (tmp) and promotes to the root's
    # lib/HookWF/tasks (project) — inside the disposable checkout so the
    # hook's root climb finds workflow.rb.
    copy['roots'] = {
      'tmp' => Path.setup(File.join(sandbox, 'HookWF', 'share', 'tasks')),
      'project' => Path.setup(File.join(sandbox, 'HookWF', 'lib', 'HookWF', 'tasks'))
    }
    copy
  end

  def register_hooked_agent(kind)
    agent = LLM::Agent.new
    agent.register_path_kind('hooked', kind)
    agent
  end

  # Promote through the agent's path tool wrapper (the shape the model
  # itself calls); normalizes the wrapper's JSON-string exception shape
  # back to a Hash so failures assert on 'exception'.
  def hooked_promote(agent, path, overwrite: nil)
    args = { 'kind' => 'hooked', 'path' => path }
    args['overwrite'] = overwrite unless overwrite.nil?
    tools = agent.other_options[:tools]
    raw = tools['path_promote'].first.call('path_promote', args)
    raw = JSON.parse(raw) if raw.is_a?(String) && raw.include?('"')
    raw.is_a?(Hash) ? raw : JSON.parse(raw.to_s)
  end

  # (3a) A real engine promote of the sandboxed task draft fires the
  # shared hook: the entrypoint re-evaluates (sentinel delta >= 1) and the
  # result carries the merged post_move report.
  def test_promote_fires_workflow_reload_through_shared_hook
    sandbox, root, draft = hook_sandbox
    kind = hooked_task_kind(sandbox)
    assert kind['promotion_post_move'].equal?(hook),
           'the sandboxed copy must carry the production hook by reference'
    agent = register_hooked_agent(kind)

    # Make the entrypoint a cached feature so the purge must remove it
    # (child-loader spelling), proving the reload is the full one.
    require File.join(root, 'workflow.rb')
    before_count = File.readlines(File.join(root, 'hook_counter')).size

    r = hooked_promote(agent, 'hooked')

    assert_equal true, r['promoted'], r.inspect
    assert File.file?(File.join(root, 'lib', 'HookWF', 'tasks', 'hooked.rb')),
           'engine move must land the promoted file'
    refute File.exist?(draft), 'source must be gone after the move'
    assert_equal 'workflow_reload', r['post_move'], r.inspect
    assert_equal true, r['reload']['ok'], r['reload'].inspect
    assert_operator r['reload']['purged'], :>=, 1,
                    'the cached entrypoint must have been purged'
    after_count = File.readlines(File.join(root, 'hook_counter')).size
    assert_operator after_count - before_count, :>=, 1,
                    'the hook-fired reload must re-evaluate the entrypoint'
  ensure
    # Drop the disposable checkout's cached features so later tests never
    # see them, then remove the sandbox.
    ($LOADED_FEATURES.delete_if { |f| f.to_s.include?(sandbox) } if sandbox)
    FileUtils.rm_rf(sandbox) if sandbox
  end

  # (3b) A REFUSED promote (no-clobber collision) never runs the hook and
  # never purges or reloads anything.
  def test_refused_promote_does_not_reload
    sandbox, root, draft = hook_sandbox
    kind = hooked_task_kind(sandbox)
    agent = register_hooked_agent(kind)

    dst = File.join(root, 'lib', 'HookWF', 'tasks', 'hooked.rb')
    File.write(dst, '# pre-existing destination')
    require File.join(root, 'workflow.rb')
    before_count = File.readlines(File.join(root, 'hook_counter')).size
    cached = $LOADED_FEATURES.find { |f| File.expand_path(f.to_s) == File.join(root, 'workflow.rb') }

    r = hooked_promote(agent, 'hooked')

    assert_match(/already exists/, r['exception'].to_s)
    assert File.file?(draft), 'refused promotion must leave the source intact'
    refute r.key?('post_move'), 'refused promote must not run the hook'
    assert_equal before_count, File.readlines(File.join(root, 'hook_counter')).size,
                 'no reload may happen on refusal'
    if cached
      assert $LOADED_FEATURES.include?(cached),
             'refused promote must not purge the cache'
    end
  ensure
    ($LOADED_FEATURES.delete_if { |f| f.to_s.include?(sandbox) } if sandbox)
    FileUtils.rm_rf(sandbox) if sandbox
  end

  # (3c) After a hook-fired reload of the REAL ScoutCoder checkout the
  # @@target_workflow memo identity is preserved and PATH_KINDS intact.
  # The hook object itself is the vehicle (called directly with args
  # naming a ScoutCoder lib destination — the same args shape the engine
  # passes), so no real file is moved.
  def test_hook_fired_reload_preserves_memo_and_path_kinds
    before = ScoutCoder.target_workflow
    refute_nil before
    memo_before = ScoutCoder.class_variable_get(:@@target_workflow) rescue nil
    refute_nil memo_before

    args = {'promotion_target' => File.join(ROOT, 'lib', 'ScoutCoder', 'path_kinds.rb'),
            'overwrite' => false}
    r = hook.call(nil, 'task/path_kinds', 'project', args)

    assert_equal 'workflow_reload', r['post_move']
    assert_equal true, r['reload']['ok']
    assert_equal File.realpath(ROOT), r['reload']['root']
    assert ScoutCoder.target_workflow.equal?(before),
           'memo must keep pointing at the SAME module object'
    assert_equal memo_before.object_id,
                 (ScoutCoder.class_variable_get(:@@target_workflow) rescue nil).object_id
    assert ScoutCoder::PATH_KINDS.is_a?(Hash) && ScoutCoder::PATH_KINDS.key?('task'),
           'the reloaded tree must re-register its kinds'
  end

  # (3d) The hook never writes to the moved path: after the engine's move
  # the promoted file's content is EXACTLY the draft content (engine move
  # only), and the hook's own call leaves a destination file untouched.
  def test_hook_never_writes_the_moved_file
    sandbox, root, draft = hook_sandbox
    kind = hooked_task_kind(sandbox)
    agent = register_hooked_agent(kind)

    r = hooked_promote(agent, 'hooked')
    assert_equal true, r['promoted'], r.inspect

    dst = File.join(root, 'lib', 'HookWF', 'tasks', 'hooked.rb')
    assert_equal "# HookWF task draft\nmodule HookWF\nend\n", File.read(dst),
                 'destination content must be exactly what the engine moved'

    # Direct hook call against an existing destination: content unchanged.
    before = File.read(dst)
    args = {'promotion_target' => dst, 'overwrite' => false}
    hook.call(nil, 'task/hooked', 'project', args)
    assert_equal before, File.read(dst),
                 'the hook must never write or move the promoted file'
  ensure
    ($LOADED_FEATURES.delete_if { |f| f.to_s.include?(sandbox) } if sandbox)
    FileUtils.rm_rf(sandbox) if sandbox
  end

  # (3e) Root derivation is deterministic and loud: no promotion_target is
  # a ParameterException, and so is a target outside any workflow
  # checkout (climb exhausted).
  def test_hook_root_derivation_fails_loudly
    assert_raise(ParameterException) { hook.call(nil, 'task/x', 'project', {}) }

    outside = File.join(@sandbox, 'plain', 'deeper', 'file.rb')
    FileUtils.mkdir_p(File.dirname(outside))
    File.write(outside, 'x')
    e = assert_raise(ParameterException) do
      hook.call(nil, 'task/x', 'project', {'promotion_target' => outside})
    end
    assert_match(/no workflow\.rb found above/, e.message)
  end
end
