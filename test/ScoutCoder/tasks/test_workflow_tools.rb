require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/, '\\1')
require 'scout'
require 'tmpdir'
require 'open3'
require 'rbconfig'

class TestWorkflowTools < Test::Unit::TestCase
  Source = <<~'RUBY'
    task :sample => :string do
      'ok'
    end
  RUBY

  def test_omission_emits_no_export
    assert_nil ScoutCoder::TaskDefinition.resolve_export_type(nil, nil)
    generated = ScoutCoder::TaskDefinition.source('sample', Source, nil)
    assert_not_match(/^\s*export(?:_exec)?\s/m, generated)
    assert_operator generated.index('task :sample'), :<, generated.index("\nend\n")
    assert_nothing_raised { RubyVM::InstructionSequence.compile(generated) }
  end

  def test_export_choices_are_emitted_and_compile
    { 'export' => "export :sample", 'export_exec' => "export_exec :sample" }.each do |choice, line|
      assert_equal choice, ScoutCoder::TaskDefinition.resolve_export_type(choice, nil)
      generated = ScoutCoder::TaskDefinition.source('sample', Source, choice)
      assert_include generated, line
      assert_operator generated.index(line), :>, generated.index("task :sample")
      assert_nothing_raised { RubyVM::InstructionSequence.compile(generated) }
    end
  end

  def test_exports_register_when_generated_source_is_loaded_in_a_fresh_process
    suffix = "#{Process.pid}_#{rand(1_000_000)}"
    names = { nil => "scoutcoder_plain_#{suffix}",
              'export' => "scoutcoder_async_#{suffix}",
              'export_exec' => "scoutcoder_exec_#{suffix}" }

    Dir.mktmpdir('scoutcoder-export-smoke') do |directory|
      names.each do |choice, name|
        source = ScoutCoder::TaskDefinition.source(name, "task :#{name} => :string do; 'ok'; end", choice)
        File.write(File.join(directory, "#{name}.rb"), source)
      end

      checks = <<~'RUBY'
        require './workflow'
        ARGV.each { |source| load source }
        plain, asynchronous, executable = ARGV.map { |source| File.basename(source, '.rb').to_sym }
        abort 'default unexpectedly registered an export' if ScoutCoder.asynchronous_exports.include?(plain) || ScoutCoder.exec_exports.include?(plain)
        abort 'export did not register as asynchronous' unless ScoutCoder.asynchronous_exports.include?(asynchronous)
        abort 'export_exec did not register as executable' unless ScoutCoder.exec_exports.include?(executable)
        puts 'fresh-load registrations passed'
      RUBY
      command = [RbConfig.ruby, '-I', File.join(Dir.pwd, 'lib'), '-e', checks,
                 *names.values.map { |name| File.join(directory, "#{name}.rb") }]
      stdout, stderr, status = Open3.capture3(*command, chdir: File.expand_path('../../..', __dir__))
      assert_predicate status, :success?, "fresh process failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
      assert_include stdout, 'fresh-load registrations passed'
    end
  end

  def test_invalid_values_are_rejected
    [false, 'none', 'export_async'].each do |value|
      assert_raise(ParameterException) do
        ScoutCoder::TaskDefinition.resolve_export_type(value, nil)
      end
    end
  end

  def test_legacy_alias_and_conflicts
    assert_equal 'export', ScoutCoder::TaskDefinition.resolve_export_type(nil, 'export')
    assert_equal 'export_exec', ScoutCoder::TaskDefinition.resolve_export_type('export_exec', 'export_exec')
    assert_raise(ParameterException) do
      ScoutCoder::TaskDefinition.resolve_export_type('export', 'export_exec')
    end
    assert_raise(ParameterException) do
      ScoutCoder::TaskDefinition.resolve_export_type(nil, 'invalid')
    end
  end
end

