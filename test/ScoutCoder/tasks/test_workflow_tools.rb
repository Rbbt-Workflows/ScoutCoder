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

  def test_define_task_reloads_and_registers_candidate
    name = "scoutcoder_reload_#{Process.pid}_#{rand(1_000_000)}"
    definition = "task :#{name} => :string do; 'registered'; end"
    script = <<~'RUBY'
      name = nil
      begin
        require './workflow'
        require 'json'
        name, definition = ARGV
        result = ScoutCoder.job(:define_task, nil, task_name: name,
                                definition: definition, export_type: 'none').run
        raise 'candidate was not registered' unless ScoutCoder.tasks.include?(name.to_sym)
        puts JSON.generate(result)
      ensure
        path = File.expand_path("share/tasks/#{name}.rb", Dir.pwd)
        File.delete(path) if name && File.file?(path)
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script,
                                             name, definition,
                                             chdir: File.expand_path('../../..', __dir__))
    assert_predicate status, :success?, "isolated define_task failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
    result = JSON.parse(stdout)
    assert_equal 'passed', result.dig('validation', 'syntax')
    assert_equal 'passed', result.dig('validation', 'load')
    assert_equal 'passed', result.dig('validation', 'registration')
    refute File.file?(File.expand_path("../../../share/tasks/#{name}.rb", __dir__))
  end

  def test_define_task_wraps_reload_failure_and_keeps_candidate
    name = "scoutcoder_reload_failure_#{Process.pid}_#{rand(1_000_000)}"
    path = File.expand_path("../../../share/tasks/#{name}.rb", __dir__)
    definition = "task :#{name} => :string do; 'registered'; end\nraise 'intentional load-time failure'"
    script = <<~'RUBY'
      name = nil
      begin
        require './workflow'
        require 'json'
        name, definition = ARGV
        ScoutCoder.job(:define_task, nil, task_name: name,
                       definition: definition, export_type: 'none').run
        raise 'define_task unexpectedly succeeded'
      rescue ParameterException => error
        path = File.expand_path("share/tasks/#{name}.rb", Dir.pwd)
        raise 'candidate missing at failure' unless File.file?(path)
        raise 'missing reload-failure context' unless error.message.include?('define_task reload failed')
        raise 'missing original load error' unless error.message.include?('RuntimeError: intentional load-time failure')
        puts JSON.generate(class: error.class.name, message: error.message, candidate_retained: true)
      ensure
        path = File.expand_path("share/tasks/#{name}.rb", Dir.pwd)
        File.delete(path) if name && File.file?(path)
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script,
                                             name, definition,
                                             chdir: File.expand_path('../../..', __dir__))
    assert_predicate status, :success?, "isolated reload-failure test failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
    result = JSON.parse(stdout)
    assert_equal 'ParameterException', result['class']
    assert_include result['message'], 'define_task reload failed'
    assert_include result['message'], 'RuntimeError: intentional load-time failure'
    assert_equal true, result['candidate_retained']
    refute File.file?(path), 'disposable candidate should be removed by subprocess cleanup'
  ensure
    File.delete(path) if path && File.file?(path)
  end
end

