require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/, '\1')
require 'test/unit'
require 'securerandom'

class TaskTestToolsTest < Test::Unit::TestCase
  def test_author_and_run_test_for_a_generated_task
    name = "task_test_tools_probe_#{Process.pid}_#{SecureRandom.hex(4)}"
    root = ScoutCoder::TaskTestSupport.project_root
    task_path = File.join(root, 'share/tasks', "#{name}.rb")
    test_path = File.join(root, 'share/test/task', "#{name}.rb")

    definition = <<~RUBY
      desc 'Uppercase the supplied value'
      input :value, :string, 'Value to uppercase'
      task :#{name} => :string do |value|
        value.upcase
      end
    RUBY

    created = ScoutCoder.job(:define_task, nil,
      task_name: name,
      definition: definition,
      export_type: 'export_exec'
    ).run
    assert_equal true, created[:written]
    assert_equal 'passed', created.dig(:validation, :syntax)

    generated_test = <<~RUBY
      require 'test/unit'
      class Generated#{name.split('_').map(&:capitalize).join}Test < Test::Unit::TestCase
        def test_uppercases_value
          step = ScoutCoder.job(:#{name}, nil, value: 'scout')
          step.clean if step.done?
          assert_equal 'SCOUT', step.run
          step.clean
        end
      end
    RUBY

    authored = ScoutCoder.job(:author_task_test, nil,
      task_name: name,
      test_source: generated_test
    ).run
    assert_equal true, authored[:written]
    assert_equal 'passed', authored[:syntax]
    assert_equal test_path, authored[:path]

    result = ScoutCoder.job(:run_task_test, nil,
      task_name: name,
      timeout_seconds: 30
    ).run
    assert_equal true, result[:passed], "generated test failed:\n#{result[:stdout]}\n#{result[:stderr]}"
    assert_match(/1 tests, 1 assertions, 0 failures, 0 errors/, result[:stdout])
  ensure
    File.delete(test_path) if test_path && File.file?(test_path)
    File.delete(task_path) if task_path && File.file?(task_path)
  end
end
