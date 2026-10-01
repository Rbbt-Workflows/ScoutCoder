require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'tmpdir'

class HelperToolsTest < Test::Unit::TestCase
  def test_define_helper_registers_helper_and_test_runs_it_from_fake_task
    name = "helper_probe_#{Process.pid}_#{SecureRandom.hex(4)}"
    helper_path = File.expand_path("../../../share/helpers/#{name}.rb", __dir__)
    test_path = File.expand_path("../../../share/test/helper/#{name}.rb", __dir__)
    marker = File.join(Dir.tmpdir, "#{name}.json")
    source = "helper :#{name} do |value|\n  value.reverse\nend"
    script = <<~'RUBY'
      require './workflow'
      require 'json'
      name, source = ARGV
      result = ScoutCoder.job(:define_helper, nil, helper_name: name, definition: source).run
      raise 'helper not registered' unless ScoutCoder.helpers.key?(name.to_sym)
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
      module ScoutCoder
        input :value, :string, 'Value passed to the test helper'
        task :#{name}_fake_task => :string do |value|
          #{name}(value)
        end
      end
      class #{name.split('_').map(&:capitalize).join}Test < Test::Unit::TestCase
        def test_helper_runs_inside_a_step
          step = ScoutCoder.job(:#{name}_fake_task, nil, value: 'scout')
          step.clean if step.done?
          assert_equal 'tuocs', step.run
        ensure
          step.clean if step
        end
      end
    RUBY
    authored = ScoutCoder.job(:author_helper_test, nil, helper_name: name, test_source: test_source).run
    assert_equal 'passed', authored[:syntax]
    assert_equal test_path, authored[:path]
    tested = ScoutCoder.job(:run_helper_test, nil, helper_name: name, timeout_seconds: 30).run
    assert_equal true, tested[:passed], "helper test failed:\n#{tested[:stdout]}\n#{tested[:stderr]}"
    assert_match(/1 tests, 1 assertions, 0 failures, 0 errors/, tested[:stdout])
  ensure
    File.delete(marker) if marker && File.file?(marker)
    File.delete(test_path) if test_path && File.file?(test_path)
    File.delete(helper_path) if helper_path && File.file?(helper_path)
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
