require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'fileutils'
require 'tmpdir'

# ---------------------------------------------------------------------------
# Anchor contract for path_run children (round: path-kinds contract fixes;
# discharges round-9 deferred item 8, "PATH_KIND_ROOT chdir tension").
#
# CONTRACT: a path_run child loads the workflow.rb of the project checkout
# that OWNS the resolved test file.
#
# Foreign regime under test (the AGS session regime): the kinds and the
# loaded ScoutCoder module come from the STRUCTURAL checkout, while the
# process CWD is a foreign project — PATH_KIND_PROJECT_ROOT unset, pinned
# kind root == ScoutCoder's own. Before the fix the child chdir'd to
# PATH_KIND_ROOT (structural) and loaded the wrong workflow.rb; evidence:
# tmp/path-kinds-contract-fixes/logs/harness-red.log.
#
# Entry path is exactly the session's: path_run TASK surface ->
# path-kind resolve -> run_for_agent -> run_child -> chdir.
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
            'path_run child did not load the foreign workflow.rb'
          assert_equal 'constant', defined?(#{FOREIGN_ENTITY}),
            'path_run child did not load the foreign entity draft'
        end
      end
    RUBY
  end

  # Entry path: the session chain resolve_path -> run_for_agent ->
  # run_child. (Round 14: the path_run TASK and TestFileSupport's
  # agent_standin retired with the path_run consolidation; the entry now
  # resolves through the production resolve hook directly. The TASK-layer
  # caching caveat that motivated the standin is gone with the task.)
  def path_run_entry(path)
    target = ScoutCoder.path_kind_resolve_test_file(path, 'tmp')
    ScoutCoder::TestFileSupport.run_for_agent(nil, target, {'scope' => 'file'})
  end

  # ------------------------------------------------------------------ tests

  def test_child_loads_foreign_workflow_when_working_from_foreign_checkout
    result = path_run_entry('probe/anchor')

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
