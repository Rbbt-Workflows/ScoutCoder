require 'fileutils'
require 'open3'
require 'rbconfig'

module ScoutCoder
  module HelperTestSupport
    HELPER_NAME = /\A[a-z][a-z0-9_]*\z/
    DEFAULT_TIMEOUT = 120

    module_function

    def validate_helper_name(name)
      value = name.to_s
      raise ArgumentError, "invalid helper name '#{value}'; expected [a-z][a-z0-9_]*" unless HELPER_NAME.match?(value)
      value
    end

    def project_root
      File.realpath(File.expand_path('../..', __dir__))
    end

    def safe_child_path(root, *parts)
      root = File.realpath(root)
      path = File.expand_path(File.join(root, *parts))
      raise ArgumentError, 'path escapes project root' unless path.start_with?(root + File::SEPARATOR)
      existing_parent = File.dirname(path)
      existing_parent = File.dirname(existing_parent) until File.exist?(existing_parent)
      resolved_parent = File.realpath(existing_parent)
      unless resolved_parent == root || resolved_parent.start_with?(root + File::SEPARATOR)
        raise ArgumentError, 'path parent escapes project root through a symlink'
      end
      path
    end

    def helper_source_path(root, name)
      name = validate_helper_name(name)
      safe_child_path(root, 'share', 'helpers', "#{name}.rb")
    end

    def test_source_path(root, name)
      name = validate_helper_name(name)
      safe_child_path(root, 'share', 'test', 'helper', "#{name}.rb")
    end

    def write_test(root, name, source)
      name = validate_helper_name(name)
      helper_path = helper_source_path(root, name)
      raise ArgumentError, "helper source does not exist: #{helper_path}" unless File.file?(helper_path) && !File.symlink?(helper_path)
      raise ArgumentError, 'test source must be non-empty Ruby source' unless source.is_a?(String) && !source.strip.empty?
      raise ArgumentError, 'RubyVM::InstructionSequence unavailable; cannot syntax-check test source' unless defined?(RubyVM::InstructionSequence)
      target = test_source_path(root, name)
      RubyVM::InstructionSequence.compile(source, target)
      FileUtils.mkdir_p(File.dirname(target))
      File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0644) { |file| file.write(source) }
      { helper: name, path: target, bytes: source.bytesize, written: true, overwritten: false,
        syntax: 'passed', execution: 'not_run' }
    rescue Errno::EEXIST
      raise ArgumentError, "test already exists: #{target}; refusing to overwrite"
    end

    def run_test(root, name, timeout_seconds: DEFAULT_TIMEOUT)
      name = validate_helper_name(name)
      root = File.realpath(root)
      helper_path = helper_source_path(root, name)
      test_path = test_source_path(root, name)
      raise ArgumentError, "helper source does not exist: #{helper_path}" unless File.file?(helper_path) && !File.symlink?(helper_path)
      raise ArgumentError, "test source does not exist: #{test_path}" unless File.file?(test_path) && !File.symlink?(test_path)
      timeout_seconds = Integer(timeout_seconds)
      raise ArgumentError, 'timeout_seconds must be positive' unless timeout_seconds.positive?

      loader = '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)'
      command = [RbConfig.ruby, '-I', File.join(root, 'lib'), '-e', loader, test_path]
      stdout = stderr = ''
      status = nil
      timed_out = false
      Open3.popen3(*command, chdir: root, pgroup: true) do |stdin, out, err, wait_thread|
        stdin.close
        readers = [Thread.new { out.read }, Thread.new { err.read }]
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
        until wait_thread.join(0.05)
          next if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          timed_out = true
          begin
            Process.kill('TERM', -wait_thread.pid)
            sleep 0.2
            Process.kill('KILL', -wait_thread.pid) if wait_thread.alive?
          rescue Errno::ESRCH
          end
          break
        end
        wait_thread.join
        status = wait_thread.value unless timed_out
        stdout = readers[0].value
        stderr = readers[1].value
        stderr = [stderr, "Test process exceeded timeout of #{timeout_seconds} seconds"].reject(&:empty?).join("\n") if timed_out
      end
      { helper: name, test_path: test_path, command: command,
        status: (timed_out ? 'timeout' : status&.exitstatus), passed: !timed_out && status&.success?,
        timed_out: timed_out, stdout: stdout, stderr: stderr,
        fresh_process: true, workflow_loaded: true,
        test_guidance: 'Helper tests must invoke the helper from within a workflow Step; define a disposable fake task in the test and run its Step.' }
    end
  end
end
