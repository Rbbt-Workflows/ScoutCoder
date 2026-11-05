require 'test/unit'
require 'fileutils'
require 'json'
require 'tmpdir'
require File.expand_path('../../test_helper.rb', __dir__)

# Step 4 (reload build): the explicit reload surface — the ScoutCoder
# `reload_workflow` task. Covers (a) fixture lib/ edit + task invocation
# reloads behaviorally, (b) the task is registered on the workflow
# (run_task-callable surface), (c) default root = the ScoutCoder checkout
# with @@target_workflow identity preserved, (d) bad root surfaces
# ParameterException, not a swallowed error.
#
# The default-root case reloads the REAL ScoutCoder checkout inside the
# test process (same discipline as test_workflow_reload.rb step-3 case:
# identical module object, memo untouched, job runs in-process).
class TestReloadWorkflowTask < Test::Unit::TestCase
  ROOT = File.expand_path('../../..', __dir__)

  def setup
    @sandbox = Dir.mktmpdir('reload-task')
  end

  def teardown
    FileUtils.rm_rf(@sandbox)
  end

  # Fixture workflow: workflow.rb requires lib file with a sentinel
  # version constant; the task's reload must pick up an edit to it.
  def seed_fixture!(dir, version = 1)
    FileUtils.mkdir_p(File.join(dir, 'lib', 'FxWf'))
    FileUtils.mkdir_p(File.join(dir, 'share'))
    File.write(File.join(dir, 'lib', 'FxWf', 'sentinel.rb'),
               "module FxWf; VERSION = #{version}; end\n")
    File.write(File.join(dir, 'workflow.rb'),
               "require_relative 'lib/FxWf/sentinel'\n" \
               "module FxWf\n  extend Workflow\nend\n")
  end

  # ScoutCoder: a directory-valued :string input digests by the
  # directory's file LISTING, so two structurally identical fixture
  # checkouts (workflow.rb + the same lib/ layout) collide on ONE job
  # path — the second replays the first's cached report. Freshness for
  # a reload is the whole point, so this runner always cleans the exact
  # job before running (doctrine: clean the exact job when freshness
  # matters; a fresh process is not a fresh result).
  def run_task(root = nil)
    args = {}
    args['root'] = root if root
    job = ScoutCoder.job(:reload_workflow, nil, args)
    job.clean
    job.run
  end

  # (b) + (a): registered surface, then behavioral edit-reload.
  def test_fixture_lib_edit_then_task_reload_new_content_in_effect
    seed_fixture!(@sandbox, 1)
    wf = Workflow.require_workflow(File.join(@sandbox, 'workflow.rb'), silent: true)
    assert_equal 1, FxWf::VERSION

    # (b) task-registry assertion, sibling style (job construction works):
    # the task lives on the ScoutCoder workflow (the surface run_task uses),
    # so construct its job there; it is invoked with the fixture root.
    job = ScoutCoder.job(:reload_workflow, nil, 'root' => @sandbox)
    assert job.is_a?(Step), 'reload_workflow must be a registered ScoutCoder task'

    seed_fixture!(@sandbox, 2) # lib/ edit while loaded
    report = run_task(@sandbox)
    assert_equal true, report['ok']
    assert_equal File.realpath(@sandbox), report['root']
    assert report['purged'].any? { |p| p.end_with?('lib/FxWf/sentinel.rb') },
           'the edited lib file must have been purged and re-required'
    assert_equal 2, FxWf::VERSION, 'new content must be in effect after reload'
  end

  # (c) default root: no root -> ScoutCoder checkout, memo identity.
  def test_default_root_is_scoutcoder_checkout_and_memo_preserved
    before = ScoutCoder.target_workflow
    report = run_task
    assert_equal true, report['ok']
    assert_equal File.realpath(ROOT), File.realpath(report['root'])
    assert report['entrypoint'].end_with?('workflow.rb')
    assert_equal 'ScoutCoder', report['workflow']
    assert ScoutCoder.target_workflow.equal?(before),
           '@@target_workflow must survive the default reload (same module object)'
  end

  # (d) bad root: ParameterException is the task's failure mode.
  def test_bad_root_raises_parameter_exception
    missing = File.join(@sandbox, 'no-such-dir')
    e = assert_raise(ParameterException) { run_task(missing) }
    assert_match(/does not exist/, e.message)

    seed_fixture!(@sandbox)
    File.delete(File.join(@sandbox, 'workflow.rb'))
    e2 = assert_raise(ParameterException) { run_task(@sandbox) }
    assert_match(/workflow\.rb/, e2.message)
  end
end
