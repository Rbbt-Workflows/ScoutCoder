require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'fileutils'
require 'tmpdir'

# ---------------------------------------------------------------------------
# Anchor contract for run_test children (round: path-kinds contract fixes;
# discharges round-9 deferred item 8, "PATH_KIND_ROOT chdir tension").
#
# CONTRACT: a run_test child loads the workflow.rb of the project checkout
# that OWNS the resolved test file.
#
# Foreign regime under test (the AGS session regime): the kinds and the
# loaded ScoutCoder module come from the STRUCTURAL checkout, while the
# process CWD is a foreign project — PATH_KIND_PROJECT_ROOT unset, pinned
# kind root == ScoutCoder's own. Before the fix the child chdir'd to
# PATH_KIND_ROOT (structural) and loaded the wrong workflow.rb; evidence:
# tmp/path-kinds-contract-fixes/logs/harness-red.log.
#
# Entry path is exactly the session's: run_test TASK surface ->
# TestFileSupport.agent_standin -> run_for_agent -> run_child -> chdir.
# The fixture is a disposable foreign checkout built at runtime under
# Dir.mktmpdir (NOT tmp/path-kinds-contract-fixes/, which is disposable
# probe material).
# ---------------------------------------------------------------------------
class TestRunTestChildAnchor < Test::Unit::TestCase
  FOREIGN_WORKFLOW = 'R9AnchorForeign'
  FOREIGN_ENTITY = 'R9AnchorWidget'

  def setup
    @saved_cwd = Dir.pwd
    @sandbox = Dir.mktmpdir('r9-anchor')
    @foreign = File.join(@sandbox, 'foreign_project')
    seed_foreign_checkout!
    Dir.chdir(@foreign)
  end

  def teardown
    Dir.chdir(@saved_cwd) if @saved_cwd && Dir.pwd != @saved_cwd
    if ScoutCoder.const_defined?(:PATH_KIND_PROJECT_ROOT, false)
      was_verbose = $VERBOSE
      $VERBOSE = nil
      ScoutCoder.send(:remove_const, :PATH_KIND_PROJECT_ROOT)
      $VERBOSE = was_verbose
    end
    FileUtils.rm_rf(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # ---------------------------------------------------------------- helpers

  # Minimal but framework-valid foreign checkout: own workflow module (NOT
  # ScoutCoder), a share/entities draft so a foreign constant provably loads,
  # and a share/test probe that asserts that constant from INSIDE the child.
  def seed_foreign_checkout!
    FileUtils.mkdir_p(File.join(@foreign, 'share', 'entities'))
    FileUtils.mkdir_p(File.join(@foreign, 'share', 'test', 'probe'))
    # Marker so Path.caller_lib_dir anchors HERE and not to an enclosing
    # project (the same reason tmp/path-kinds-contract-fixes/harness carries
    # a README.md).
    File.write(File.join(@foreign, 'README.md'), "# disposable fixture\n")

    File.write(File.join(@foreign, 'workflow.rb'), <<~RUBY)
      require 'scout'

      module #{FOREIGN_WORKFLOW}
        extend Workflow
      end

      #{FOREIGN_WORKFLOW}.extend LiveWorkflow
    RUBY

    File.write(File.join(@foreign, 'share', 'entities', 'anchor_widget.rb'), <<~RUBY)
      module #{FOREIGN_ENTITY}
        extend Entity
      end
    RUBY

    File.write(File.join(@foreign, 'share', 'test', 'probe', 'anchor.rb'), <<~RUBY)
      require 'test/unit'

      puts "PROBE PWD=\#{Dir.pwd}"
      puts "PROBE workflow_constant=\#{defined?(#{FOREIGN_WORKFLOW}).inspect}"
      puts "PROBE entity_constant=\#{defined?(#{FOREIGN_ENTITY}).inspect}"

      class AnchorProbe < Test::Unit::TestCase
        def test_child_loaded_foreign_workflow
          assert_equal 'constant', defined?(#{FOREIGN_WORKFLOW}),
            'run_test child did not load the foreign workflow.rb'
          assert_equal 'constant', defined?(#{FOREIGN_ENTITY}),
            'run_test child did not load the foreign entity draft'
        end
      end
    RUBY
  end

  # Entry path: the session chain agent_standin -> resolve_path ->
  # run_for_agent -> run_child. The run_test TASK is a thin wrapper over
  # exactly this call (tasks/test_runner_tools.rb); going through the task
  # would add the Scout JOB layer, whose cache key does not include the
  # runtime fixture path — a second run in another tmpdir would replay the
  # FIRST run's result (stale workflow_loaded pointing at a deleted
  # sandbox). Observed live during this bout; that is a caching property
  # of the task surface, not of the anchor under test.
  def run_test_entry(path)
    agent = ScoutCoder::TestFileSupport.agent_standin
    target = agent.resolve_path('test_file', path, 'tmp')
    ScoutCoder::TestFileSupport.run_for_agent(agent, target, {'scope' => 'file'})
  end

  # ------------------------------------------------------------------ tests

  def test_child_loads_foreign_workflow_when_working_from_foreign_checkout
    result = run_test_entry('probe/anchor')

    assert_equal 1, result['count'], 'exactly the probe file must run'
    r = result['results'].first
    assert_equal true, r['passed'], "probe must pass; stdout:\n#{r['stdout']}"
    assert_equal @foreign, r['workflow_loaded'],
                 "workflow_loaded must name the foreign checkout (got #{r['workflow_loaded']})"
    assert_match("PROBE PWD=#{@foreign}", r['stdout'].to_s)
    assert_match("PROBE workflow_constant=\"constant\"", r['stdout'].to_s)
    assert_match("PROBE entity_constant=\"constant\"", r['stdout'].to_s)
  end

  def test_project_root_override_still_wins
    was_verbose = $VERBOSE
    $VERBOSE = nil
    ScoutCoder.const_set(:PATH_KIND_PROJECT_ROOT, @foreign)
    $VERBOSE = was_verbose

    assert_equal @foreign,
                 ScoutCoder.child_checkout(file: File.join(@foreign, 'share', 'test', 'probe', 'anchor.rb')),
                 'PATH_KIND_PROJECT_ROOT (suite seam) must take priority over file ownership'
  end

  def test_scoutcoder_tree_file_anchors_to_scoutcoder_from_foreign_cwd
    real_test = File.expand_path('../test_path_kinds.rb', __dir__)
    assert_equal File.expand_path('../..', __dir__),
                 ScoutCoder.child_checkout(file: real_test),
                 'a ScoutCoder-tree file must anchor to the ScoutCoder checkout even from a foreign CWD'
  end

  def test_no_marker_file_falls_back_to_structural_root
    markerless = File.join(@sandbox, 'nowhere', 'share', 'test', 'x.rb')
    FileUtils.mkdir_p(File.dirname(markerless))
    File.write(markerless, "# no checkout above this point\n")

    assert_equal ScoutCoder::PATH_KIND_ROOT, ScoutCoder.child_checkout(file: markerless),
                 'a file under no recognizable checkout falls back to PATH_KIND_ROOT'
  end
end
