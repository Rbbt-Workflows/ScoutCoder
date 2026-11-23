require File.expand_path(__FILE__).sub(%r{/test/.*}, '/test/test_helper.rb')
require File.expand_path('../../../workflow.rb', __dir__) unless defined?(ScoutCoder::WorkflowReload)

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# ---------------------------------------------------------------------------
# WO2 regression coverage for the reload-deferral change in
# lib/ScoutCoder/path_kinds/workflow_reload.rb (PROMOTION_POST_MOVE).
#
# Contract under test (WO1 design, verbatim in tmp/wo1/wo1-evidence.md):
#   * defer_reload: true on path_promote threads through the engine's
#     verbatim caller-arg merge (path.rb:1725-1731) into the shared hook,
#     which SKIPS reload_workflow! and returns promotion_status='deferred'
#     plus deferred_reload=<root to reload later>;
#   * immediate promote merges hook keys under the engine's promoted/
#     destination keys (path.rb:1732, engine keys win): promotion_status=
#     'succeeded' + reload {ok, root, purged, mode};
#   * immediate promote whose reload FAILS reports the completed move with
#     promotion_status='reload_failed' and the ORIGINAL diagnostic verbatim
#     in reload.error — never a bare exception envelope with the move
#     silently intact (the field failure this change repairs);
#   * the hook raises only when it cannot construct a report at all (no
#     promotion_target). A promotion_target above NO workflow.rb (root
#     discovery failure) RETURNS 'reload_failed' with the climb diagnostic
#     in reload.error and NO 'root' key: the destination is known, so the
#     caller must still see the completed-move receipt (WO5 reconciliation;
#     previously this arm raised too).
#
# Every test drives the REAL promotion entrypoint (LLM::Agent + per-agent
# registered copies of the production kinds with roots pinned into a
# disposable fixture checkout under Dir.mktmpdir — the round-11 harness
# pattern; the copies carry the production PROMOTION_POST_MOVE lambda by
# reference, equal?-asserted). The five-step test finishes in a genuinely
# fresh process (spawned child) so nothing here depends on warm state.
# ---------------------------------------------------------------------------
class TestPromotionReloadDeferral < Test::Unit::TestCase
  ROOT = File.expand_path('../../..', __dir__)

  def setup
    @sandbox = Dir.mktmpdir('wo2-defer')
  end

  def teardown
    ($LOADED_FEATURES.delete_if { |f| f.to_s.include?(@sandbox) } if @sandbox)
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # Resolve the hook at CALL time: other suites reload the real ScoutCoder
  # checkout mid-run, re-creating the lambda (same discipline as
  # test_workflow_reload.rb).
  def hook
    ScoutCoder::WorkflowReload::PROMOTION_POST_MOVE
  end

  # ---- fixture ----------------------------------------------------------

  # Disposable checkout: entity + property drafts under share/, an (at
  # first unwired) workflow.rb with LiveWorkflow. +Wired adds the promoted
  # lib requires AROUND the LiveWorkflow share load (entity BEFORE, property
  # AFTER) exactly as the work order's wiring rule demands.
  def build_fixture(name, entity:, property:)
    @wf_name = name
    @fx = File.join(@sandbox, name)
    FileUtils.mkdir_p(File.join(@fx, 'lib', name, 'entity', entity))
    FileUtils.mkdir_p(File.join(@fx, 'share', 'entities'))
    FileUtils.mkdir_p(File.join(@fx, 'share', 'entity_properties', entity))
    File.write(File.join(@fx, 'workflow.rb'), workflow_rb)
    File.write(File.join(@fx, 'share', 'entities', "#{entity}.rb"), <<~RUBY)
      module #{entity}
        extend Entity
      end
    RUBY
    File.write(File.join(@fx, 'share', 'entity_properties', entity, "#{property}.rb"), <<~RUBY)
      module #{entity}
        property :#{property} do
          'early'
        end
      end
    RUBY
    @entity = entity
    @property = property
  end

  def workflow_rb(wired: false)
    head = "# disposable WO2 fixture — NOT ScoutCoder\n" \
           "require 'scout'\nrequire 'scout-ai'\n" \
           "module #{@wf_name}\n  extend Workflow\nend\n"
    return head + "#{@wf_name}.extend LiveWorkflow\n" unless wired
    head +
      "require_relative 'lib/#{@wf_name}/entity/#{@entity}'\n" \
      "#{@wf_name}.extend LiveWorkflow\n" \
      "require_relative 'lib/#{@wf_name}/entity/#{@entity}/#{@property}'\n"
  end

  def lib_entity_file
    File.join(@fx, 'lib', @wf_name, 'entity', "#{@entity}.rb")
  end

  def lib_property_file
    File.join(@fx, 'lib', @wf_name, 'entity', @entity, "#{@property}.rb")
  end

  # Per-agent copies of the PRODUCTION entity/entity_property kinds with
  # roots pinned into the fixture (shallow dup — a Proc hook cannot be
  # Marshal-copied; the hook keeps production identity, asserted by the
  # caller). Registered under aliases so the production names on other
  # agents are untouched.
  def pinned_agent
    defs = {}
    {'wo2_entity' => ['entity', 'entities'],
     'wo2_property' => ['entity_property', 'entity_properties']}.each do |alias_name, (kind, share_dir)|
      copy = {}
      ScoutCoder::PATH_KINDS[kind].each { |k, v| copy[k] = v.is_a?(Hash) ? v.dup : v }
      copy['roots'] = {
        'tmp' => Path.setup(File.join(@fx, 'share', share_dir)),
        'project' => Path.setup(File.join(@fx, 'lib', @wf_name, 'entity'))
      }
      defs[alias_name] = copy
    end
    agent = LLM::Agent.new
    defs.each do |alias_name, copy|
      assert copy['promotion_post_move'].equal?(hook),
             "sandboxed #{alias_name} must carry the production hook by reference"
      agent.register_path_kind(alias_name, copy)
    end
    agent
  end

  # Promote through the agent's real path_promote tool callable (the shape
  # the model itself calls); defer: true adds the ScoutCoder-only caller
  # argument the engine merges into hook args verbatim.
  def promote(agent, kind, path, defer: false)
    args = {'kind' => kind, 'path' => path}
    args['defer_reload'] = true if defer
    raw = agent.other_options[:tools]['path_promote'].first.call('path_promote', args)
    raw = JSON.parse(raw) if raw.is_a?(String) && raw.include?('"')
    raw.is_a?(Hash) ? raw : JSON.parse(raw.to_s)
  end

  # ---- (a) five-step sequence --------------------------------------------

  def test_five_step_deferred_promotions_wire_once_reload_once_fresh_process
    build_fixture('DeferFx', entity: 'GeneD', property: 'onset')
    agent = pinned_agent

    # 1. promote the ENTITY with defer_reload: no reload may happen yet.
    r1 = promote(agent, 'wo2_entity', 'GeneD', defer: true)
    assert_equal true, r1['promoted'], r1.inspect
    assert_equal 'deferred', r1['promotion_status'], r1.inspect
    assert_equal 'workflow_reload_deferred', r1['post_move'], r1.inspect
    assert_equal File.expand_path(@fx), r1['deferred_reload'], r1.inspect
    assert File.file?(lib_entity_file), 'entity must land in lib/'
    refute File.exist?(File.join(@fx, 'share', 'entities', 'GeneD.rb')),
           'engine move must remove the draft'
    # Deferral evidence: nothing from this fixture was loaded or purged.
    assert $LOADED_FEATURES.select { |f| f.to_s.include?(@sandbox) }.empty?,
           'a deferred promotion must not load or purge anything'

    # 2. promote the PROPERTY with defer_reload: still no reload — the
    # half-promoted-set trap (drafted property evaluated against an entity
    # not yet supplying `property`) never triggers.
    r2 = promote(agent, 'wo2_property', 'GeneD/onset', defer: true)
    assert_equal true, r2['promoted'], r2.inspect
    assert_equal 'deferred', r2['promotion_status'], r2.inspect
    assert File.file?(lib_property_file), 'property must land in lib/'
    assert $LOADED_FEATURES.select { |f| f.to_s.include?(@sandbox) }.empty?,
           'still nothing loaded after the second deferred promotion'

    # 3. wire workflow.rb ourselves: entity require BEFORE the LiveWorkflow
    # share load, property require AFTER.
    File.write(File.join(@fx, 'workflow.rb'), workflow_rb(wired: true))

    # Cache the fixture's features so the explicit reload must visibly purge
    # and re-evaluate them (verifiable execution, not a no-op).
    require File.join(@fx, 'workflow.rb')
    entry = File.join(File.realpath(@fx), 'workflow.rb')
    assert $LOADED_FEATURES.include?(entry), 'entrypoint must be cached before the reload'

    # 4. exactly ONE explicit reload, through the documented agent-facing
    # invocation (the debug_task TOOL carrying reload_workflow with an
    # explicit root and clean: true — see the forced-reload pinning test).
    # Pinned rule (WO5): an explicit-root reload_workflow job executed via
    # debug_task WITHOUT clean replays the cached job when one exists; clean
    # forces exactly one fresh execution.
    reload_job = ScoutCoder.job(:reload_workflow, nil, 'root' => @fx)
    reload_job.clean
    report = reload_job.run
    assert_equal true, report['ok'], report.inspect
    assert_equal File.realpath(@fx), report['root']
    assert_includes report['purged'], entry, 'the cached entrypoint must be purged'
    assert report['purged'].any? { |p| p.end_with?("lib/#{@wf_name}/entity/GeneD.rb") },
                'the promoted entity feature must be purged and re-evaluated'
    assert report['purged'].any? { |p| p.end_with?('GeneD/onset.rb') },
                'the promoted property feature must be purged and re-evaluated'
    assert_equal 'required', report['reload']
    # In-process postcondition after the single reload.
    assert_equal 'early', GeneD.setup('X').onset,
                 'the wired, reloaded fixture must dispatch the property'

    # 5. FRESH PROCESS: a spawned child loads only the fixture's
    # workflow.rb and calls the property through a configured entity.
    child = <<~RUBY
      require #{File.join(@fx, 'workflow.rb').inspect}
      puts GeneD.setup('X').onset
    RUBY
    stdout, status = Open3.capture2e(RbConfig.ruby, '-e', child)
    assert status.success?, "fresh-process child failed: #{stdout}"
    assert_equal "early\n", stdout,
                 'the fresh process must resolve the property through the wired fixture'
  ensure
    Object.send(:remove_const, :GeneD) if defined?(GeneD) && @sandbox.to_s.include?('DeferFx')
  end

  # ---- (b) immediate promotion, reload succeeds ---------------------------

  def test_immediate_promote_reports_engine_and_hook_keys
    build_fixture('ImmFx', entity: 'GeneI', property: 'onset')
    # The immediate-reload arm must succeed: no drafted property may remain
    # (a drafted property would reproduce the field failure: reload loads the
    # property file against an entity not yet supplying `property`).
    FileUtils.rm_rf(File.join(@fx, 'share', 'entity_properties', 'GeneI'))
    agent = pinned_agent

    r = promote(agent, 'wo2_entity', 'GeneI')

    # Engine-owned keys.
    assert_equal true, r['promoted'], r.inspect
    assert_equal 'GeneI', r['path']
    assert_equal({'location' => 'project', 'path' => 'GeneI'}, r['destination'], r.inspect)
    assert_equal File.join(@fx, 'lib', @wf_name, 'entity', 'GeneI.rb'), r['promotion_target']
    # Hook-added keys (engine keys win on collision; these are additive).
    assert_equal 'succeeded', r['promotion_status'], r.inspect
    assert_equal 'workflow_reload', r['post_move'], r.inspect
    assert_equal true, r['reload']['ok'], r['reload'].inspect
    assert_equal File.realpath(@fx), r['reload']['root']
    assert r['reload']['mode'] == 'required' || r['reload']['mode'] == 're-evaluated'
    # purged is the COUNT of purged feature entries (compact receipt; the
    # full list lives in reload_workflow!'s own report).
    assert_kind_of Integer, r['reload']['purged'], r['reload'].inspect
    # Filesystem truth: the reload really re-evaluated the fixture.
    assert File.file?(File.join(@fx, 'lib', @wf_name, 'entity', 'GeneI.rb'))
    refute File.exist?(File.join(@fx, 'share', 'entities', 'GeneI.rb'))
  end

  # ---- (c) immediate promotion, reload fails deterministically ------------

  def test_reload_failure_reports_completed_move_with_verbatim_diagnostic
    build_fixture('FailFx', entity: 'GeneF', property: 'onset')
    agent = pinned_agent

    # Deterministic reload failure: break the entrypoint the reload must
    # re-evaluate. The engine move itself needs no valid workflow.rb.
    File.open(File.join(@fx, 'workflow.rb'), 'a') { |f| f.puts 'this is not ruby ^' }

    r = promote(agent, 'wo2_property', 'GeneF/onset')

    # The caller-visible result is a REPORT, not an exception envelope.
    assert r.is_a?(Hash), "expected a result Hash, got: #{r.inspect}"
    assert_equal true, r['promoted'], r.inspect
    assert_equal({'location' => 'project', 'path' => 'GeneF/onset'}, r['destination'], r.inspect)
    assert_equal lib_property_file, r['promotion_target'], r.inspect
    assert_equal 'reload_failed', r['promotion_status'], r.inspect
    assert_equal 'workflow_reload', r['post_move'], r.inspect
    assert_equal false, r['reload']['ok'], r['reload'].inspect

    # The diagnostic is the ORIGINAL normalized message, verbatim: compare
    # against a direct reload_workflow! call on the same broken root.
    direct = begin
      ScoutCoder::WorkflowReload.reload_workflow!(root: @fx)
      nil
    rescue ParameterException => e
      e.message
    end
    refute_nil direct, 'the broken fixture must still fail a direct reload'
    assert_equal direct, r['reload']['error'],
                 'the result must carry the original diagnostic verbatim'
    assert_match(/SyntaxError|reload_workflow! failed/, r['reload']['error'])
    assert_equal File.expand_path(@fx), r['reload']['root']

    # The move is unmistakably complete: draft gone, project file present
    # with the exact draft content.
    refute File.exist?(File.join(@fx, 'share', 'entity_properties', 'GeneF', 'onset.rb')),
           'the source draft must be gone (move completed)'
    assert File.file?(lib_property_file), 'the promoted project file must be present'
    assert_match(/property :onset do/, File.read(lib_property_file),
                 'destination content must be the moved draft body')
  end

  # ---- (d) canonical paired test promotes and RUNS from the project side --

  def test_paired_test_maps_to_test_onset_and_runs_from_project
    @wf_name = 'PairFx'
    @fx = File.join(@sandbox, 'PairFx')
    FileUtils.mkdir_p(File.join(@fx, 'share', 'test'))
    FileUtils.mkdir_p(File.join(@fx, 'test', 'PairFx'))
    File.write(File.join(@fx, 'workflow.rb'), <<~RUBY)
      require 'scout'
      require 'scout-ai'
      module PairFx
        extend Workflow
        MARKER = :pair_ok
      end
    RUBY

    # Per-agent copy of the PRODUCTION test_file kind with both Ruby roots
    # pinned into the fixture (registered AS 'test_file' so the resolve
    # hook's registered-root lookup flows through the copy's pinned roots).
    copy = {}
    ScoutCoder::PATH_KINDS['test_file'].each { |k, v| copy[k] = v.is_a?(Hash) ? v.dup : v }
    copy['roots'] = {
      'tmp' => Path.setup(File.join(@fx, 'share', 'test')),
      'project' => Path.setup(File.join(@fx, 'test', 'PairFx')),
      'python' => Path.setup(File.join(@fx, 'python', 'test'))
    }
    agent = LLM::Agent.new
    assert copy['promotion_post_move'].equal?(hook)
    agent.register_path_kind('test_file', copy)

    # Canonical virtual path (no dotted third segment).
    src = <<~RUBY
      require 'test/unit'
      class TestPairFxMarker < Test::Unit::TestCase
        def test_marker
          assert_equal :pair_ok, PairFx::MARKER
        end
      end
    RUBY
    raw = agent.other_options[:tools]['path_write'].first.call(
      'path_write', {'kind' => 'test_file',
                     'path' => 'entity_property/Gene/onset',
                     'content' => src})
    w = raw.is_a?(String) ? JSON.parse(raw) : raw
    assert w.key?('target') || w['written'] || w['ok'], w.inspect

    # Mapping receipt: canonical virtual path -> tmp Gene.onset.rb, project
    # test_onset.rb; the DOTTED spelling is the trap (test_Gene.onset.rb).
    assert_equal File.join(@fx, 'share', 'test', 'entity_property', 'Gene', 'Gene.onset.rb'),
                 agent.resolve_path('test_file', 'entity_property/Gene/onset', 'tmp').to_s
    assert_equal File.join(@fx, 'test', 'PairFx', 'entity', 'Gene', 'test_onset.rb'),
                 agent.resolve_path('test_file', 'entity_property/Gene/onset', 'project').to_s
    assert_equal File.join(@fx, 'test', 'PairFx', 'entity', 'Gene', 'test_Gene.onset.rb'),
                 agent.resolve_path('test_file', 'entity_property/Gene/Gene.onset', 'project').to_s

    # Promote the paired test; the shared hook reloads the fixture (valid
    # workflow.rb) and the result reports success.
    r = promote(agent, 'test_file', 'entity_property/Gene/onset')
    assert_equal true, r['promoted'], r.inspect
    assert_equal 'succeeded', r['promotion_status'], r.inspect
    assert_equal({'location' => 'project', 'path' => 'entity_property/Gene/onset'},
                 r['destination'], r.inspect)
    assert File.file?(File.join(@fx, 'test', 'PairFx', 'entity', 'Gene', 'test_onset.rb')),
           'the paired test must land at test_onset.rb on the project side'
    refute File.exist?(File.join(@fx, 'share', 'test', 'entity_property', 'Gene', 'Gene.onset.rb'))

    # RUN it from the project location through the kind's path_run custom
    # operation (engine dispatch — the machinery under the tool wrapper).
    rr = agent.path_dispatch(kind: 'test_file', operation: 'path_run',
                             'path' => 'entity_property/Gene/onset',
                             'location' => 'project', 'scope' => 'file')
    rr = rr.is_a?(String) ? JSON.parse(rr) : rr
    assert_equal true, rr['ok'], rr.inspect
    assert_equal 1, rr['passed'], rr.inspect
    assert_equal 1, rr['count'], rr.inspect
    assert_equal 0, rr['failed'], rr.inspect
    assert_equal 0, rr['not_run'], rr.inspect
    assert rr['results'].first['file'].to_s.end_with?('entity/Gene/test_onset.rb'),
           rr['results'].inspect
    assert_equal true, rr['results'].first['passed'], rr['results'].first.inspect
  ensure
    ($LOADED_FEATURES.delete_if { |f| f.to_s.include?(@sandbox) } if @sandbox)
    Object.send(:remove_const, :PairFx) if defined?(PairFx)
  end

  # ---- hook-only arms (no engine) ----------------------------------------

  def test_hook_raises_only_when_no_report_is_constructable
    # Arm (1) — nothing to anchor on: still the ONLY raise.
    assert_raise(ParameterException) { hook.call(nil, 'entity/x', 'project', {}) }
  end

  def test_hook_reports_root_discovery_failure_instead_of_raising
    # Arm (2) — a promotion_target above NO workflow.rb. The destination is
    # known, so the caller must receive the completed-move receipt, not an
    # exception envelope (WO5 reconciliation; a fourth status is
    # deliberately NOT introduced: a caller's recovery action — inspect the
    # destination — is identical for root-discovery and reload-execution
    # failure, and reload.error carries the distinction verbatim).
    outside = File.join(@sandbox, 'plain', 'deep', 'f.rb')
    FileUtils.mkdir_p(File.dirname(outside))
    File.write(outside, 'x')

    r = hook.call(nil, 'entity/x', 'project', {'promotion_target' => outside})

    assert_equal 'reload_failed', r['promotion_status'], r.inspect
    assert_equal 'workflow_reload', r['post_move'], r.inspect
    assert_equal false, r['reload']['ok'], r['reload'].inspect
    assert_match(/no workflow\.rb found above/, r['reload']['error'])
    assert_includes r['reload']['error'], outside
    refute r['reload'].key?('root'),
           'root-discovery failure must not claim a root (none was derivable)'
    refute r['reload'].key?('purged'), 'nothing may be purged when no root was found'
  end

  def test_hook_reload_report_carries_purged_as_count_and_no_entrypoint
    # Pin the reconciled receipt-field contract (WO5): the promote result's
    # reload sub-hash carries `purged` as the COUNT of purged feature
    # entries and NO `entrypoint` key; the full list + entrypoint stay in
    # reload_workflow!'s own report. Asserted against a real successful
    # promote through the engine entrypoint, not the hook in isolation.
    build_fixture('CntFx', entity: 'GeneC', property: 'onset')
    FileUtils.rm_rf(File.join(@fx, 'share', 'entity_properties', 'GeneC'))
    agent = pinned_agent

    # Cache fixture features first so the reload has something real to purge.
    require File.join(@fx, 'workflow.rb')

    r = promote(agent, 'wo2_entity', 'GeneC')
    assert_equal 'succeeded', r['promotion_status'], r.inspect
    reload = r['reload']
    assert_equal true, reload['ok'], reload.inspect
    assert_kind_of Integer, reload['purged'], reload.inspect
    assert_operator reload['purged'], :>=, 1,
                    'the cached fixture entrypoint must have been purged'
    refute reload.key?('entrypoint'),
           'the promote receipt deliberately omits entrypoint (compact form)'
    # The keys the receipt DOES carry: exactly {ok, root, purged, mode}.
    assert_equal %w[ok mode purged root].sort, reload.keys.sort, reload.inspect
  end

  # ---- (e) installed public tool schema (WO5 step 3) ----------------------

  def test_installed_path_promote_schema_declares_defer_reload
    # The engine (dev checkout, live in this process) OWNS the path_promote
    # tool definition; ScoutCoder only registers kinds. Assert against the
    # agent's actual tool options after a real integration so this pins the
    # INSTALLED surface, not a hand-written copy of it.
    agent = LLM::Agent.new
    agent.integrate_workflow_path_kinds(ScoutCoder)
    entry = agent.other_options[:tools]['path_promote']
    assert entry, 'path_promote tool must be installed after integration'
    _callable, schema = entry

    props = schema['parameters']['properties']
    assert_equal false, schema['parameters']['additionalProperties'],
                 'strict validation must be preserved'
    assert_equal %w[kind path], schema['parameters']['required'].sort

    dr = props['defer_reload']
    assert dr, 'defer_reload must be declared in the installed schema'
    assert_equal 'boolean', dr['type'], dr.inspect
    refute schema['parameters']['required'].include?('defer_reload'),
           'defer_reload must be omittable (immediate reload stays the default)'

    # The engine's flag description is itself part of the contract.
    assert_match(/skip the automatic post-promotion workflow reload/i,
                 dr['description'].to_s)

    # No unrelated property smuggled in: the schema stays exactly the five
    # documented parameters.
    assert_equal %w[defer_reload kind location overwrite path].sort, props.keys.sort,
                 props.keys.inspect
  end

  # ---- (f) forced reload through the DOCUMENTED agent invocation (WO5) ----

  def test_forced_reload_via_debug_task_executes_exactly_once_per_clean
    # Execution-sentinel fixture (WO6 recalibration): workflow.rb requires a
    # lib feature whose body APPENDS one mark to a log file. Because the
    # sentinel feature is required through require_relative from the
    # entrypoint, every full evaluation pass of the entrypoint re-executes
    # the feature once the reload's purge has un-cached it — so ONE mark
    # corresponds to ONE reload EXECUTION performed by ANY process, under
    # ANY engine variant. The prior counter-in-entrypoint design counted
    # one reload execution as 2 increments on the dev engine (require +
    # require_workflow Kernel#load re-evaluation — the both-branch design
    # of reload_workflow!) and as 1 on the gem engine (Critic environment,
    # WO5 gate finding): constant arithmetic over an engine-variant-
    # dependent count is exactly what this recalibration removes. Zero or
    # TWO+ new marks both fail the exact-count assertions below.
    @wf_name = 'ForceFx'
    @fx = File.join(@sandbox, 'ForceFx')
    FileUtils.mkdir_p(File.join(@fx, 'lib', 'ForceFx'))
    exec_log = File.join(@fx, 'exec_log')
    File.write(exec_log, '')
    File.write(File.join(@fx, 'workflow.rb'), <<~RUBY)
      require 'scout'
      require 'scout-ai'
      module ForceFx
        extend Workflow
      end
      require_relative 'lib/ForceFx/mark'
    RUBY
    File.write(File.join(@fx, 'lib', 'ForceFx', 'mark.rb'),
               "File.open(#{exec_log.inspect}, 'a') { |f| f.write 'x' }\n")
    execs = -> { File.read(exec_log).size }

    # Cache the fixture features in THIS process so a real reload must purge
    # them (verifiable freshness, not a no-op).
    require File.join(@fx, 'workflow.rb')
    entry = File.join(File.realpath(@fx), 'workflow.rb')
    assert $LOADED_FEATURES.include?(entry), 'entrypoint must be cached first'
    baseline = execs.call

    # The documented invocation shape (README # reload_workflow / PathKinds
    # debug_task section): the debug_task TOOL carries the reload_workflow task,
    # root names the fixture checkout, and clean — an input of the TOOL, not
    # of reload_workflow — forces a fresh execution.
    call = lambda do |clean|
      ScoutCoder.job(:debug_task, nil,
                     'workflow' => 'ScoutCoder',
                     'task' => 'reload_workflow',
                     'inputs' => JSON.generate('root' => @fx),
                     'clean' => clean).run
    end

    # SEED — establish "a cached reload job for the fixture root"
    # deterministically: clean the DIRECT reload_workflow job for this root
    # and run it once. Engine-variant robustness (WO6, measured on BOTH the
    # dev checkout engine and the gem engine scout-ai 2.1.0): one reload
    # execution produces EXACTLY ONE sentinel mark on both variants (the
    # prior counter-in-entrypoint design produced 2 on dev / 1 on gem — the
    # WO5 gate finding), and the direct job's digest is root-keyed on both,
    # so clean+run always executes fresh here. This seed call is itself the
    # calibration proof: 1 mark == 1 execution on THIS engine.
    seed_job = ScoutCoder.job(:reload_workflow, nil, 'root' => @fx)
    seed_job.clean
    seed = seed_job.run
    assert_equal true, seed['ok'], seed.inspect
    assert_equal File.realpath(@fx), seed['root'], seed.inspect
    seed_marks = execs.call - baseline
    assert_equal 1, seed_marks,
                 "one direct reload execution must produce exactly one sentinel mark, got #{seed_marks}"
    assert_includes seed['purged'], entry,
                    'the cached entrypoint must be purged (proof of freshness)'
    assert seed['purged'].any? { |p| p.end_with?('lib/ForceFx/mark.rb') },
           'the fixture lib feature must be purged and re-evaluated'
    after_seed = execs.call

    # WARM — populate the no-clean WRAPPED job's cache slot without
    # asserting its mark count. Measured on both engines: whether this call
    # executes or replays depends on job-store history (the gem engine does
    # not key the wrapped task's root into the no-clean digest and can
    # replay an unrelated earlier reload_workflow job cross-root and
    # cross-process), so its execution count is deliberately NOT part of
    # the pinned substance — only the calls below are.
    warm = call.call(false)
    assert_equal 'done', warm[:status], warm.inspect
    after_warm = execs.call

    # Pinned rule #1 (SUBSTANCE) — WITH clean: exactly ONE new execution
    # (ONE new sentinel mark), no cache replay, provably fresh (non-empty
    # purge of the previously-cached fixture features; the report names
    # THIS fixture). Fails by design on ZERO new executions (replayed
    # instead of executing) and on TWO+ new executions. The reload MODE is
    # deliberately NOT asserted: it is engine-variant-dependent
    # ('required' measured on both variants here, but the purge + single
    # mark are the variant-independent freshness proof).
    r3 = call.call(true)
    assert_equal 'done', r3[:status], r3.inspect
    assert_equal false, r3[:cache_replay], r3.inspect
    clean_pass = execs.call - after_warm
    assert_equal 1, clean_pass,
                 "clean must execute the reload exactly once, got #{clean_pass}"
    assert_equal true, r3[:output]['ok'], r3[:output].inspect
    assert_equal File.realpath(@fx), r3[:output]['root'], r3[:output].inspect
    assert_includes r3[:output]['purged'], entry,
                    'the cached entrypoint must be purged (proof of freshness)'
    assert r3[:output]['purged'].any? { |p| p.end_with?('lib/ForceFx/mark.rb') },
           'the fixture lib feature must be purged and re-evaluated'

    # Pinned rule #2 (SUBSTANCE) — the subsequent call WITHOUT clean
    # replays the cache: ZERO new sentinel marks (measured cache_replay
    # true on the gem engine and false-but-zero-marks on the dev engine,
    # so the mark count — not the flag — is the pinned invariant).
    r4 = call.call(false)
    assert_equal 'done', r4[:status], r4.inspect
    assert_equal 0, execs.call - after_warm - clean_pass,
                 'the no-clean call after clean must replay, not execute again'
  ensure
    Object.send(:remove_const, :ForceFx) if defined?(ForceFx)
  end

end
