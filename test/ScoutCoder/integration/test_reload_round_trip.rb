require 'test/unit'
require 'fileutils'
require 'json'
require 'tmpdir'
require File.expand_path('../../test_helper.rb', __dir__)

# Step 5 (reload build): the consumer round trip on a disposable fixture
# workflow under tmp/, exercising BOTH acceptance scenarios in one flow:
#
#   1. PROMOTE TRIGGER: load fixture -> promote a draft from its share/ to
#      its lib/ through the REAL promote operation (agent tool surface,
#      sandboxed copy of the production task kind, same pattern as
#      test_workflow_reload.rb) -> the promotion_post_move hook fires the
#      full reload: stale share-path feature purged, promoted lib/ version
#      in effect behaviorally.
#   2. EXPLICIT TRIGGER: edit a lib/ file of the same fixture -> invoke the
#      ScoutCoder `reload_workflow` task with the fixture root -> new
#      content in effect behaviorally.
class TestReloadIntegrationRoundTrip < Test::Unit::TestCase
  ROOT = File.expand_path('../../..', __dir__)

  def setup
    @sandbox = Dir.mktmpdir('reload-integration')
    @saved_cwd = Dir.pwd
  end

  def teardown
    Dir.chdir(@saved_cwd) if Dir.pwd != @saved_cwd
    FileUtils.rm_rf(@sandbox)
  end

  def seed_fixture!
    # Minimal checkout: workflow.rb has NO require of its own (so the
    # promote destination does not pre-exist; the lib file is created BY
    # the promote). The share/ draft carries VERSION = :share and the
    # promoted lib version sets :lib.
    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'tasks'))
    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'test'))
    FileUtils.mkdir_p(File.join(@sandbox, 'lib', 'FxWf', 'tasks'))
    File.write(File.join(@sandbox, 'workflow.rb'),
               "module FxWf\n  extend Workflow\nend\n")
    File.write(File.join(@sandbox, 'share', 'tasks', 'versioned.rb'),
               "require 'scout'\n" \
               "module FxWf; VERSION = :share; end\n")
  end

  # Sandboxed copy of the production task kind, roots pinned to the
  # fixture, same shallow-dup pattern as test_workflow_reload.rb (a Proc
  # hook makes Marshal-copy impossible; recorded there).
  def register_hooked_agent
    copy = {}
    ScoutCoder::PATH_KINDS['task'].each { |k, v| copy[k] = v.is_a?(Hash) ? v.dup : v }
    copy['roots'] = {
      'tmp' => Path.setup(File.join(@sandbox, 'share', 'tasks')),
      'project' => Path.setup(File.join(@sandbox, 'lib', 'FxWf', 'tasks'))
    }
    copy['project_root'] = @sandbox
    agent = LLM::Agent.new
    agent.register_path_kind('task', copy)
    agent
  end

  def promote(agent)
    raw = agent.other_options[:tools]['path_promote'].first.call(
      'path_promote', { 'kind' => 'task', 'path' => 'versioned' })
    Hash === raw ? raw : JSON.parse(raw)
  end

  def test_promote_then_lib_edit_round_trip
    seed_fixture!
    Dir.chdir(@sandbox) do
      # Load the fixture: only the share draft exists at first (the lib
      # file is created BY the promote), and it is loaded explicitly,
      # caching the share spelling — the stale state the fix targets.
      wf = Workflow.require_workflow('./workflow.rb', silent: true)
      share_feature = File.join(@sandbox, 'share', 'tasks', 'versioned.rb')
      require share_feature
      assert_equal :share, FxWf::VERSION
      assert wf.equal?(Workflow.require_workflow('./workflow.rb', silent: true))

      # 1. PROMOTE through the real agent surface: hook reloads the fixture.
      agent = register_hooked_agent
      r = promote(agent)
      assert_equal true, r['promoted'], r.inspect
      assert File.file?(File.join(@sandbox, 'lib', 'FxWf', 'tasks', 'versioned.rb'))
      refute File.exist?(share_feature), 'engine moved the draft away'
      # The purge matches by realpath on both sides (the helper's pinned
      # rule); the share file is already GONE, so compare realpaths the
      # same way rather than raw $LOADED_FEATURES strings.
      share_real = File.realpath(share_feature) if File.exist?(share_feature)
      stale = share_real && $LOADED_FEATURES.any? do |f|
        real = begin
          File.realpath(File.expand_path(f.to_s))
        rescue StandardError
          nil
        end
        real == share_real
      end
      refute stale, 'stale share-path feature must be purged by the hook reload'

      # The promote result carries the hook's merged report: the reload
      # ran and targeted the fixture checkout.
      assert_equal 'workflow_reload', r['post_move'], r.inspect
      assert_equal true, r['reload']['ok'], r['reload'].inspect
      assert_equal File.realpath(@sandbox), r['reload']['root']

      # The promoted file, now in its lib home, loads and defines the
      # module from THAT spelling (no stale share cache blocks it).
      lib_feature = File.join(@sandbox, 'lib', 'FxWf', 'tasks', 'versioned.rb')
      require lib_feature
      assert $LOADED_FEATURES.include?(lib_feature),
             'the promoted lib file must be loadable from its new home'
      refute_nil FxWf::VERSION, 'module defined by the promoted file'

      # 2. EXPLICIT TRIGGER: lib edit + reload_workflow task.
      File.write(File.join(@sandbox, 'lib', 'FxWf', 'tasks', 'versioned.rb'),
                 "require 'scout'\n" \
                 "module FxWf\n  VERSION = :edited\n  def self.marker; :edited; end\nend\n")
      $LOADED_FEATURES.delete_if { |f| f.to_s.include?(@sandbox) }
      require File.join(@sandbox, 'lib', 'FxWf', 'tasks', 'versioned.rb')
      assert_equal :edited, FxWf::VERSION, 'edited content after fresh require'
      assert_equal :edited, FxWf.marker
      # ScoutCoder: directory-valued :string inputs digest by file
      # LISTING, so identical-layout fixtures collide on one job path
      # (see test_reload_workflow_task.rb); clean the exact job before
      # running — a reload task's value IS the fresh execution.
      reload_job = ScoutCoder.job(:reload_workflow, nil, 'root' => @sandbox)
      reload_job.clean
      report = reload_job.run
      assert_equal true, report['ok'], report.inspect
      assert report['purged'].any? { |p| p.end_with?('lib/FxWf/tasks/versioned.rb') }
      assert_equal :edited, FxWf::VERSION,
                   'edited lib content must be in effect after the explicit reload'
    end
  end
end
