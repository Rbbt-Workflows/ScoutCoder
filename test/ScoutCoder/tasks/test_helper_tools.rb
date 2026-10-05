require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'tmpdir'

class HelperToolsTest < Test::Unit::TestCase
  def test_define_helper_registers_helper_and_test_runs_it_from_fake_task
    name = "helper_probe_#{Process.pid}_#{SecureRandom.hex(4)}"
    helper_path = File.expand_path("../../../tmp/workflows/TestWF/share/helpers/#{name}.rb", __dir__)
    task_path = File.expand_path("../../../tmp/workflows/TestWF/share/tasks/scoped_probe_#{Process.pid}.rb", __dir__)
    test_path = File.expand_path("../../../tmp/workflows/TestWF/share/test/helper/#{name}.rb", __dir__)
    marker = File.join(Dir.tmpdir, "#{name}.json")
    source = <<~'RUBY'.sub('HELPER_NAME', name)
      helper :HELPER_NAME do |left, right|
        "#{left}-#{right}"
      end
    RUBY
    script = <<~'RUBY'
      require File.expand_path('workflow', Dir.pwd)
      require 'scout/workflow/live'
      require 'pathname'
      require 'json'
      require 'fileutils'
      name, source = ARGV
      test_workflow_file = File.expand_path('tmp/workflows/TestWF/workflow.rb', Dir.pwd)
      FileUtils.mkdir_p(File.dirname(test_workflow_file))
      File.write(test_workflow_file, <<~'WORKFLOW')
        require 'scout'
        require 'scout-ai'
        require 'scout/workflow/live'
        module TestWF
          extend Workflow
          self.libdir = __dir__
          extend ::LiveWorkflow
        end
      WORKFLOW
      Workflow.require_workflow_file(Pathname.new(test_workflow_file))
      result = ScoutCoder.job(:define_helper, nil, helper_name: name, definition: source,
                              workflow: 'TestWF').run
      raise 'helper not registered' unless TestWF.helpers.key?(name.to_sym)
      task_name = "scoped_probe_#{Process.pid}"
      raise 'candidate helper not scoped to target workflow' unless TestWF.helpers.key?(name.to_sym)
      FileUtils.mkdir_p(File.join(TestWF.libdir, 'share', 'tasks'))
      task_source = ['module TestWF', "  task :#{task_name} => :string do; #{name}('left', 'right'); end", 'end', ''].join(10.chr)
      File.write(File.join(TestWF.libdir, 'share', 'tasks', "#{task_name}.rb"), task_source)
      TestWF.load_live_files!
      step = TestWF.job(task_name.to_sym)
      step.clean if step.done?
      raise "multi-argument helper failed: #{step.run.inspect}" unless step.run == 'left-right'
      TestWF.load_live_files!
      raise 'candidate task missing from target workflow' unless TestWF.tasks.key?(task_name.to_sym)
      raise 'candidate helper leaked into ScoutCoder' if ScoutCoder.helpers.key?(name.to_sym)
      File.write(ENV.fetch('HELPER_TEST_MARKER'), JSON.generate(result))
    RUBY
    test_root = File.expand_path('../../..', __dir__)
    stdout, stderr, status = Open3.capture3({ 'HELPER_TEST_MARKER' => marker }, RbConfig.ruby, '-Ilib', '-e', script,
                                             name, source,
                                             chdir: test_root)
    assert_predicate status, :success?, "isolated define_helper failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
    result = JSON.parse(File.read(marker))
    assert_equal true, result['written']
    assert_equal 'passed', result.dig('validation', 'registration')
    assert File.file?(helper_path)

    test_source = <<~RUBY
      require 'test/unit'
      module TestWF
        input :value, :string, 'First value passed to the test helper'
        input :suffix, :string, 'Second value passed to the test helper'
        task :#{name}_fake_task => :string do |value, suffix|
          #{name}(value, suffix)
        end
      end
      class #{name.split('_').map(&:capitalize).join}Test < Test::Unit::TestCase
        def test_helper_runs_inside_a_step
          step = TestWF.job(:#{name}_fake_task, nil, value: 'left', suffix: 'right')
          step.clean if step.done?
          assert_equal 'left-right', step.run
        ensure
          step.clean if step
        end
      end
    RUBY
    require 'pathname'
    Workflow.require_workflow_file(Pathname.new(File.expand_path('../../../tmp/workflows/TestWF/workflow.rb', __dir__)))
    authored = ScoutCoder.job(:author_helper_test, nil, helper_name: name, test_source: test_source, workflow: 'TestWF').run
    assert_equal 'passed', authored[:syntax]
    assert_equal test_path, authored[:path]
    tested = ScoutCoder.job(:run_helper_test, nil, helper_name: name, timeout_seconds: 30, workflow: 'TestWF').run
    assert_equal true, tested[:passed], "helper test failed:\n#{tested[:stdout]}\n#{tested[:stderr]}"
    assert_match(/1 tests, 1 assertions, 0 failures, 0 errors/, tested[:stdout])
  ensure
    File.delete(marker) if marker && File.file?(marker)
    File.delete(test_path) if test_path && File.file?(test_path)
    File.delete(helper_path) if helper_path && File.file?(helper_path)
    FileUtils.rm_rf(File.join(File.dirname(File.dirname(helper_path)), 'share')) if helper_path && File.directory?(File.join(File.dirname(File.dirname(helper_path)), 'share'))
  end

  def test_invalid_name_and_invalid_declaration_are_rejected
    assert_raise(ParameterException) do
      ScoutCoder.job(:define_helper, nil, helper_name: '../oops', definition: 'helper :oops do; end').run
    end
    assert_raise(ParameterException) do
      ScoutCoder.job(:define_helper, nil, helper_name: 'valid_name', definition: 'helper :other do; end').run
    end
  end
end
