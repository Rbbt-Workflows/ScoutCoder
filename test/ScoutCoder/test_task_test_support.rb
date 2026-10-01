require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/, '\\1')
require 'tmpdir'
require 'fileutils'

class TestTaskTestSupport < Test::Unit::TestCase
  Support = ScoutCoder::TaskTestSupport

  def with_project
    Dir.mktmpdir('scoutcoder-test-support') do |root|
      FileUtils.mkdir_p(File.join(root, 'share', 'tasks'))
      File.write(File.join(root, 'workflow.rb'), "require 'test/unit'\n")
      File.write(File.join(root, 'share', 'tasks', 'sample.rb'), '# task fixture')
      yield root
    end
  end

  def test_names_and_paths_are_constrained
    with_project do |root|
      assert_equal File.join(root, 'share', 'tasks', 'sample.rb'), Support.task_source_path(root, 'sample')
      assert_raise(ArgumentError) { Support.task_source_path(root, '../escape') }
      assert_raise(ArgumentError) { Support.test_source_path(root, 'nested/name') }
    end
  end

  def test_authoring_requires_existing_task_and_does_not_overwrite
    with_project do |root|
      source = "require 'test/unit'\nclass AuthoredTest < Test::Unit::TestCase\n  def test_ok; assert_equal 2, 1 + 1; end\nend\n"
      result = Support.write_test(root, 'sample', source)
      assert_equal true, result[:written]
      assert_equal 'passed', result[:syntax]
      assert_equal source, File.read(File.join(root, 'share', 'test', 'task', 'sample.rb'))
      assert_raise(ArgumentError) { Support.write_test(root, 'sample', source) }
      assert_raise(ArgumentError) { Support.write_test(root, 'missing', source) }
    end
  end

  def test_runner_uses_fresh_process_and_returns_test_status
    with_project do |root|
      test_path = Support.test_source_path(root, 'sample')
      FileUtils.mkdir_p(File.dirname(test_path))
      File.write(test_path, "require 'test/unit'\nclass RunnerTest < Test::Unit::TestCase\n  def test_pass; assert_equal 4, 2 + 2; end\nend\n")
      result = Support.run_test(root, 'sample', timeout_seconds: 10)
      assert_equal true, result[:fresh_process]
      assert_equal true, result[:passed]
      assert_equal 0, result[:status]
      assert_match(/1 tests, 1 assertions, 0 failures, 0 errors/, result[:stdout])
    end
  end

  def test_runner_reports_failure_status
    with_project do |root|
      test_path = Support.test_source_path(root, 'sample')
      FileUtils.mkdir_p(File.dirname(test_path))
      File.write(test_path, "require 'test/unit'\nclass RunnerFailureTest < Test::Unit::TestCase\n  def test_fail; assert_equal 1, 2; end\nend\n")
      result = Support.run_test(root, 'sample', timeout_seconds: 10)
      assert_equal false, result[:passed]
      assert_equal 1, result[:status]
      assert_match(/1 failures/, result[:stdout])
    end
  end
end
