require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/, '\1')
require 'fileutils'
require 'securerandom'

class TestLiveWorkflow < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)
  LIB = File.join(ROOT, 'lib')
  SCRATCH = File.join(ROOT, 'tmp', 'live_probe_wf')

  def self.shutdown
    FileUtils.rm_rf(SCRATCH)
  end

  def self.scratch_module
    @scratch_sequence ||= 0
    @scratch_sequence += 1
    "LiveProbe#{format('%02d', @scratch_sequence)}#{SecureRandom.hex(3)}"
  end

  def build_scratch(module_name, files = {})
    root = File.join(SCRATCH, module_name)
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(File.join(root, 'lib'))
    # README.md anchors Path.caller_lib_dir at the scratch root; without it
    # libdir would walk up to the ScoutCoder checkout and resolve its share.
    File.write(File.join(root, 'README.md'), "# scratch workflow\n")
    files.each do |relative, content|
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    File.write(File.join(root, 'workflow.rb'), <<~RUBY)
      require 'scout'
      $LOAD_PATH.unshift(#{LIB.inspect}) unless $LOAD_PATH.include?(#{LIB.inspect})
      require 'ScoutCoder/LiveWorkflow'

      module #{module_name}
        extend Workflow
        extend ScoutCoder::LiveWorkflow
      end
    RUBY
    root
  end

  def entry(root)
    File.join(root, 'workflow.rb')
  end

  def task_source(module_name, task)
    "module #{module_name}\n  desc '#{task}'\n  task :#{task} do '#{task} ok' end\nend\n"
  end

  def require_scratch(root, update: nil)
    Workflow.require_workflow(entry(root), update: update)
  end

  def test_extend_hook_loads_share_tasks_and_helpers
    name = self.class.scratch_module
    root = build_scratch(name,
      'share/tasks/alpha.rb' => task_source(name, :lw_alpha),
      'share/helpers/beta.rb' => "module #{name}\n  helper :lw_beta do 'beta ok' end\nend\n")
    workflow = require_scratch(root)
    assert_equal name, workflow.to_s
    assert_include workflow.tasks.keys, :lw_alpha
    assert_include workflow.helpers.keys, :lw_beta
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_workflow_reevaluation_picks_up_added_task_file
    name = self.class.scratch_module
    root = build_scratch(name, 'share/tasks/one.rb' => task_source(name, :lw_one))
    workflow = require_scratch(root)
    assert_include workflow.tasks.keys, :lw_one
    refute workflow.tasks.key?(:lw_two)
    File.write(File.join(root, 'share/tasks/two.rb'), task_source(name, :lw_two))
    # Re-evaluating workflow.rb re-extends ScoutCoder::LiveWorkflow, which
    # re-fires self.extended and therefore reloads the share drafts. This is
    # also the empirical proof that Module#extended re-fires on re-extend:
    # load_live_files! is never called here.
    require_scratch(root, update: true)
    workflow = Object.const_get(name)
    assert_include workflow.tasks.keys, :lw_two
    assert_include workflow.tasks.keys, :lw_one
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_explicit_reload_without_workflow_reevaluation
    name = self.class.scratch_module
    root = build_scratch(name, 'share/tasks/one.rb' => task_source(name, :lw_one))
    workflow = require_scratch(root)
    refute workflow.tasks.key?(:lw_extra)
    File.write(File.join(root, 'share/tasks/extra.rb'), task_source(name, :lw_extra))
    workflow.load_live_files!
    assert_include workflow.tasks.keys, :lw_extra
    assert_include workflow.tasks.keys, :lw_one
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_entities_load_before_entity_properties
    entity = "LwEntity#{SecureRandom.hex(3)}"
    name = self.class.scratch_module
    root = build_scratch(name,
      'share/entities/gamma.rb' => "module #{entity}\n  extend Entity\nend\n",
      'share/entity_properties/gamma.rb' => "module #{entity}\n  property :lw_prop do 'prop ok' end\nend\n")
    workflow = require_scratch(root)
    ordered = ScoutCoder::LiveWorkflow.ordered_share_files(workflow)
    entity_index = ordered.index { |file| file.end_with?(File.join('share', 'entities', 'gamma.rb')) }
    property_index = ordered.index { |file| file.end_with?(File.join('share', 'entity_properties', 'gamma.rb')) }
    assert_not_nil entity_index
    assert_not_nil property_index
    assert_operator entity_index, :<, property_index

    module_constant = Object.const_get(entity)
    assert_include module_constant.properties.keys, :lw_prop
    assert_equal 'prop ok', module_constant.setup('sample').lw_prop

    # Reversed order loses the property: re-extending Entity resets property
    # metadata, so a property file loaded before its entity file ends up
    # unregistered. This is why the loader ordering is part of the contract.
    load File.join(root, 'share/entity_properties/gamma.rb')
    load File.join(root, 'share/entities/gamma.rb')
    assert_not_include module_constant.properties.keys, :lw_prop
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_ordered_share_files_ordering_and_exclusions
    entity = "LwOrder#{SecureRandom.hex(3)}"
    name = self.class.scratch_module
    root = build_scratch(name,
      'share/tasks/zz.rb' => task_source(name, :lw_zz),
      'share/tasks/nested/aa.rb' => task_source(name, :lw_aa),
      'share/helpers/h.rb' => "module #{name}\n  helper :lw_h do 'h ok' end\nend\n",
      'share/entities/e.rb' => "module #{entity}\n  extend Entity\nend\n",
      'share/entity_properties/p.rb' => "module #{entity}\n  property :lw_p do 'p ok' end\nend\n",
      'share/entity/sample.identifiers.tsv' => "#Sample\tOther\n",
      'share/test/task/poison.rb' => "raise 'must not load'\n",
      'share/test/helper/poison.rb' => "raise 'must not load'\n")
    workflow = require_scratch(root)
    ordered = ScoutCoder::LiveWorkflow.ordered_share_files(workflow)
    assert_equal 5, ordered.length
    ordered.each do |file|
      assert_match(%r{/share/(tasks|helpers|entities|entity_properties)/}, file)
      assert_not_match(%r{/share/test/}, file)
      assert_not_match(/\.tsv\z/, file)
    end
    index = ordered.to_h { |file| [File.join(root, file.delete_prefix(root + File::SEPARATOR)), ordered.index(file)] }
    %w[share/tasks/zz.rb share/tasks/nested/aa.rb share/helpers/h.rb
       share/entities/e.rb share/entity_properties/p.rb].each do |relative|
      assert_not_nil index[File.join(root, relative)], "missing #{relative} in #{ordered.inspect}"
    end
    # Subdirectory order: tasks, then helpers, then entities, then properties.
    assert_operator index[File.join(root, 'share/tasks/zz.rb')], :<, index[File.join(root, 'share/helpers/h.rb')]
    assert_operator index[File.join(root, 'share/helpers/h.rb')], :<, index[File.join(root, 'share/entities/e.rb')]
    assert_operator index[File.join(root, 'share/entities/e.rb')], :<, index[File.join(root, 'share/entity_properties/p.rb')]
    # Top-level drafts load before nested ones inside a subdirectory.
    assert_operator index[File.join(root, 'share/tasks/zz.rb')], :<, index[File.join(root, 'share/tasks/nested/aa.rb')]
    assert_include Object.const_get(entity).properties.keys, :lw_p
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_missing_share_directories_and_missing_share_are_no_ops
    root = root2 = nil
    name = self.class.scratch_module
    root = build_scratch(name)
    workflow = require_scratch(root)
    assert_empty workflow.tasks
    assert_empty workflow.helpers

    other = self.class.scratch_module
    root2 = build_scratch(other)
    %w[tasks helpers entities entity_properties].each do |sub|
      FileUtils.mkdir_p(File.join(root2, 'share', sub))
    end
    workflow2 = require_scratch(root2)
    assert_empty workflow2.tasks
    assert_empty workflow2.helpers
  ensure
    FileUtils.rm_rf(root) if root
    FileUtils.rm_rf(root2) if root2
  end

  def test_share_test_files_are_never_loaded
    name = self.class.scratch_module
    root = build_scratch(name,
      'share/tasks/one.rb' => task_source(name, :lw_one),
      'share/test/task/poison.rb' => "raise 'must not load'\n",
      'share/test/helper/poison.rb' => "raise 'must not load'\n")
    workflow = require_scratch(root)
    assert_include workflow.tasks.keys, :lw_one
    assert_nothing_raised { workflow.load_live_files! }
    assert File.file?(File.join(root, 'share/test/task/poison.rb'))
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_removed_task_file_is_tolerated_on_reload
    name = self.class.scratch_module
    root = build_scratch(name,
      'share/tasks/one.rb' => task_source(name, :lw_one),
      'share/tasks/two.rb' => task_source(name, :lw_two))
    workflow = require_scratch(root)
    File.delete(File.join(root, 'share/tasks/one.rb'))
    assert_nothing_raised { workflow.load_live_files! }
    assert_include workflow.tasks.keys, :lw_two
    remaining = ScoutCoder::LiveWorkflow.ordered_share_files(workflow)
    assert_not_include remaining, File.join(root, 'share/tasks/one.rb')
    # lw_one may survive in memory for the process lifetime (documented Ruby
    # limitation); only no-error and continued loading are guaranteed.
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_consecutive_reloads_are_idempotent
    name = self.class.scratch_module
    root = build_scratch(name,
      'share/tasks/one.rb' => task_source(name, :lw_one),
      'share/tasks/two.rb' => task_source(name, :lw_two),
      'share/helpers/h.rb' => "module #{name}\n  helper :lw_h do 'h ok' end\nend\n")
    workflow = require_scratch(root)
    task_count = workflow.tasks.keys.length
    helper_count = workflow.helpers.keys.length
    assert_equal 2, task_count
    assert_equal 1, helper_count
    assert_nothing_raised do
      workflow.load_live_files!
      workflow.load_live_files!
    end
    assert_equal task_count, workflow.tasks.keys.length
    assert_equal helper_count, workflow.helpers.keys.length
  ensure
    FileUtils.rm_rf(root) if root
  end
end
