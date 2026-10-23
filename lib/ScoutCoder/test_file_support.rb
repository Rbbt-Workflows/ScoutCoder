# Shared runner for the `test_file` path kind and the `run_test` ScoutCoder
# task (round 9, research/test-file-path-kind-guide.md §5-§6).
#
# ONE runner, two entry surfaces:
#   * the custom path operation `run_test` on the test_file kind
#     (operations table in path_kinds/test_file.rb), and
#   * the ScoutCoder task `run_test` in tasks/test_runner_tools.rb.
#
# Every file runs in a FRESH child process
# (`RbConfig.ruby -I <checkout>/lib -e LOADER <file>`, chdir: the checkout
# root) with the loader used by every other fresh-process runner in this
# repo:
#   $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)
# so the test file sees the loaded workflow (LiveWorkflow live-loads every
# share/ draft) and then itself via Kernel#load.
#
# TIMEOUTS (guide §6): per-file defaults 120s (file and directory scopes),
# 300s for suite scope; every call site may override with timeout_seconds.
# The timeout discipline follows the retired task-test runner convention:
# TERM the process
# group, wait up to 10s, KILL it if still alive.
require 'open3'
require 'rbconfig'

module ScoutCoder
  module TestFileSupport
    FILE_TIMEOUT = 120
    DIRECTORY_TIMEOUT = 120
    SUITE_TIMEOUT = 300
    TERM_GRACE = 10

    # Round-10 step 6: declared, validated bounds for the per-file timeout.
    # MIN: a zero/negative timeout would KILL every child before it could
    # report anything. MAX: the discipline is TERM -> 10s grace -> KILL, so
    # anything beyond an hour is a runaway nobody is watching; 3600s caps
    # the suite-scope default (300s) and any explicit override with headroom.
    MIN_TIMEOUT = 1
    MAX_TIMEOUT = 3600

    # Validate a caller-supplied timeout_seconds against the declared
    # bounds; returns the Integer or raises ParameterException.
    def self.normalize_timeout(value, what = 'timeout_seconds')
      return FILE_TIMEOUT if value.nil?
      n = begin
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
      if n.nil?
        raise ParameterException, "#{what} must be an integer (#{MIN_TIMEOUT}..#{MAX_TIMEOUT}): #{value.inspect}"
      end
      unless (MIN_TIMEOUT..MAX_TIMEOUT).cover?(n)
        raise ParameterException, "#{what} must be between #{MIN_TIMEOUT} and #{MAX_TIMEOUT} seconds: #{n}"
      end
      n
    end

    SUMMARY_RE = /(\d+)\s+tests?,\s*(\d+)\s+assertions?,\s*(\d+)\s+failures?,\s*(\d+)\s+errors?/

    class << self
      # A minimal agent stand-in exposing exactly resolve_path for the
      # test_file kind, so the workflow task can drive the same dispatch
      # path the engine uses without a live LLM agent.
      def agent_standin
        agent = Object.new
        agent.define_singleton_method(:resolve_path) do |kind, path, location|
          raise ParameterException, "Unknown path kind: #{kind}" unless kind.to_s == 'test_file'
          ScoutCoder.path_kind_resolve_test_file(path, location)
        end
        agent
      end

      # Run ONE test file in a fresh child process. `file` is an absolute
      # path inside the current checkout. Returns a result hash with the
      # four guide §4 exit classes:
      #   passed / failed  -> the file loaded and its tests RAN (ok: true)
      #   unloadable       -> LoadError, syntax error, or no test ran (ok: false)
      #   timed_out        -> exceeded timeout_seconds (ok: false)
      def run_file(file, timeout_seconds: FILE_TIMEOUT)
        timeout_seconds = normalize_timeout(timeout_seconds)
        agent = Thread.current[:scoutcoder_run_agent]

        if file.to_s.end_with?('.py')
          return run_python_file(file, timeout_seconds: timeout_seconds.to_i, agent: agent)
        end

        out, err, status, timed_out, checkout = run_child(file, timeout_seconds: timeout_seconds.to_i, agent: agent)
        summary = out.to_s.lines.reverse.lazy.map(&:strip).detect { |l| l =~ SUMMARY_RE }
        tests = summary ? Regexp.last_match(1).to_i : 0
        if timed_out || status.nil? || status.signaled?
          klass = 'timeout'
        elsif summary
          klass = status.success? ? 'clean_pass' : 'assertion_failure'
        else
          klass = 'load_error'
        end

        tests = 0 if klass == 'load_error' || klass == 'timeout'
        {'file' => file,
         'workflow_loaded' => checkout.to_s,
         'exit_class' => klass,
         'exit_status' => status ? status.exitstatus : nil,
         'passed' => klass == 'clean_pass',
         'ran' => %w[clean_pass assertion_failure].include?(klass),
         'ok' => %w[clean_pass assertion_failure].include?(klass),
         'timed_out' => klass == 'timeout',
         'tests' => tests,
         'summary' => summary,
         'stdout' => out,
         'stderr' => err}
      end

      # Run EVERY test file under an absolute directory (recursive). Empty
      # discovery is a ParameterException, matching the empty-path
      # semantics of run_for_agent.
      def run(root, timeout_seconds: DIRECTORY_TIMEOUT, files: nil)
        root = File.expand_path(root)
        raise ParameterException, "run: not a directory: #{root}" unless File.directory?(root)

        files ||= discover(root)
        raise ParameterException, "run: no test files found under #{root}" if files.empty?

        files.collect { |f| run_file(f, timeout_seconds: timeout_seconds) }
      end

      # Discover test files under one absolute root: `**/*.rb`, recursive,
      # sorted. Both spellings are kept: project side is conventionally
      # `test_`-prefixed, tmp (share) side is conventionally unprefixed.
      # Round 11 (python tier): `.py` files are discovered alongside `.rb`
      # so directory and suite scopes include the Python tier; each file is
      # dispatched by extension in run_file.
      def discover(root)
        root = File.expand_path(root)
        raise ParameterException, "discover: not a directory: #{root}" unless File.directory?(root)

        (Dir.glob(File.join(root, '**', '*.rb')) +
         Dir.glob(File.join(root, '**', '*.py'))).sort
      end

      # ---------------------------------------------------- python runner

      PYTHON = ENV.fetch('PYTHON', 'python3').freeze
      # unittest summary lines: "Ran N tests" + the verdict tail.
      PYTHON_SUMMARY_RE = /\bRan\s+(\d+)\s+tests?/.freeze
      PYTHON_VERDICT_RE = /\A\s*(OK|FAILED|NO TESTS RAN)/.freeze

      # Run ONE Python unittest file in a fresh child process, mirroring
      # run_child's process discipline (pgroup, TERM -> grace -> KILL,
      # bounded timeout) and run_file's honest-result contract.
      #
      # Runner choice (round-11 b1 probes, tmp/path_kinds/round11/pytest/):
      # the gem provides NO Python test runner (scout-rig's python/ ships
      # only the scout package; ScoutPython offers task/metadata runners,
      # not unittest discovery), so the STANDARD library runner serves:
      # `python3 -m unittest <module>` — the ONLY invocation whose exit
      # codes are meaningful (0 pass, 1 failures/errors, 5 no tests ran).
      # `unittest discover` ignores -p patterns with embedded quotes
      # (probe b1b) and its discovery root semantics need a module
      # package; per-module invocation needs none of that.
      #
      # PYTHONPATH is seeded from ScoutPython.paths (the live scout-rig
      # package, python/ dir of the gem — same source the python_task kind
      # uses; never the dead ~/git/scout-rig checkout hardcode).
      # PYTHONDONTWRITEBYTECODE keeps __pycache__ out of the test tree
      # (asserted by the probes/tests).
      def run_python_file(file, timeout_seconds:, agent: nil)
        file = file.to_s
        checkout = python_checkout_for(file, agent)
        module_name = File.basename(file, '.py')

        env = {
          'PYTHONDONTWRITEBYTECODE' => '1',
          'PYTHONPATH' => python_paths.join(File::PATH_SEPARATOR)
        }
        argv = [PYTHON, '-m', 'unittest', module_name]

        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = Process.spawn(env, *argv, chdir: File.dirname(file),
                            out: out_w, err: err_w, pgroup: true)
        out_w.close
        err_w.close

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
        status = nil

        timed_out = false
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          break if status

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            timed_out = true
            status = term_group(pid)
            status = reap(pid) if status.nil?
            break
          end

          sleep 0.1
        end

        out = Thread.new { out_r.read }.value
        err = Thread.new { err_r.read }.value
        out_r.close
        err_r.close

        combined = out.to_s + "\n" + err.to_s
        summary = combined.lines.reverse.lazy.map(&:strip).detect { |l| l =~ PYTHON_SUMMARY_RE }
        tests = summary ? Regexp.last_match(1).to_i : 0
        verdict = combined.lines.map(&:strip).detect { |l| l =~ PYTHON_VERDICT_RE }
        verdict &&= verdict.strip

        if timed_out || status.nil? || status.signaled?
          klass = 'timeout'
        elsif tests.zero?
          # exit 5 ("NO TESTS RAN") or a file that never reached the runner
          # (import error surfaces as errors>=1 with tests>0; a file with
          # zero discovered tests is a load_error, not a pass).
          klass = 'load_error'
        else
          klass = status.success? ? 'clean_pass' : 'assertion_failure'
        end

        tests = 0 if klass == 'timeout'

        {'file' => file,
         'workflow_loaded' => checkout.to_s,
         'exit_class' => klass,
         'exit_status' => status ? status.exitstatus : nil,
         'passed' => klass == 'clean_pass',
         'ran' => %w[clean_pass assertion_failure].include?(klass),
         'ok' => %w[clean_pass assertion_failure].include?(klass),
         'timed_out' => klass == 'timeout',
         'tests' => tests,
         'summary' => summary,
         'verdict' => verdict,
         'runner' => argv.join(' '),
         'stdout' => out,
         'stderr' => err}
      end

      # PYTHONPATH entries for the child: the live scout-rig python dirs
      # (ScoutPython.paths is seeded from Scout.python.find_all at load).
      def python_paths
        ScoutPython.paths.compact
      rescue StandardError
        begin
          Scout.python.find_all.compact
        rescue StandardError
          []
        end
      end

      # The workflow checkout owning a Python test: same anchor contract as
      # run_child's ScoutCoder.child_checkout (python/test lives inside the
      # checkout, so the parent directory walk finds workflow.rb).
      def python_checkout_for(file, agent)
        return File.dirname(file) if File.exist?(File.join(File.dirname(file), 'workflow.rb'))
        candidate = File.expand_path('..', File.expand_path(file))
        until candidate == '/' || candidate.nil?
          return candidate if File.exist?(File.join(candidate, 'workflow.rb'))
          candidate = File.dirname(candidate)
        end
        File.dirname(file)
      end

      # Entry for the run_test surfaces: resolves the target through the
      # agent's test_file kind, then dispatches on scope.
      #
      #   scope=file      -> target must exist and be a file (DEFAULT when
      #                      scope is omitted — round-10 step 6 made scope
      #                      optional; the schema no longer marks it required)
      #   scope=directory -> target is the prefix root; every discovered
      #                      test file under it runs
      #   scope=suite     -> BOTH location roots (path is the root selector,
      #                      usually ".")
      #
      # timeout_seconds is validated against MIN_TIMEOUT..MAX_TIMEOUT
      # (1..3600) by normalize_timeout; out-of-range values raise
      # ParameterException before any child process spawns.
      #
      # Empty discovery is a ParameterException (guide: no silent no-op).
      def run_for_agent(agent, target, args)
        scope = args.fetch('scope', 'file')
        timeout = normalize_timeout(args['timeout_seconds'])
        # Carry the agent (engine kind registration) into run_file so the
        # child-checkout anchor can consult the pinned kind roots (foreign
        # incorporation regime). Thread-local because run_file's signature
        # is part of the task surface; cleared on exit.
        saved = Thread.current[:scoutcoder_run_agent]
        Thread.current[:scoutcoder_run_agent] = agent
        begin
          run_for_agent_with_agent(agent, target, scope, timeout, args)
        ensure
          Thread.current[:scoutcoder_run_agent] = saved
        end
      end

      def run_for_agent_with_agent(agent, target, scope, timeout, args)

        case scope
        when 'file'
          unless File.file?(target.to_s)
            raise ParameterException, "run_test: test_file at '#{target}' does not exist or is not a file"
          end
          wrap_result(scope, [run_file(target.to_s, timeout_seconds: timeout || FILE_TIMEOUT)], target)
        when 'directory'
          unless File.directory?(target.to_s)
            raise ParameterException, "run_test: '#{target}' is not a directory"
          end
          files = discover(target.to_s)
          raise ParameterException, "run_test: no test files found under #{target}" if files.empty?
          wrap_result(scope, files.collect { |f| run_file(f, timeout_seconds: timeout || DIRECTORY_TIMEOUT) }, target)
        when 'suite'
          # Round-11 conformance: the engine now authorizes the primary
          # custom-operation target against the DISPATCHED kind's pinned
          # root (path_authorize!), so suite scope must enumerate the same
          # kind the dispatcher resolved — derived from `target` (the
          # resolved tmp root, '.' maps to the location root) instead of
          # resolving through the hard-coded 'test_file' name, which a
          # differently-named kind copy (the suite's empty probe, a foreign
          # incorporation) would deny or mis-enumerate.
          # resolve_path appends the kind extension even to the root
          # selector ('.' -> '<root>/.rb'), so recover the actual directory:
          # the resolved target itself when it IS a directory, else its
          # dirname with a trailing extension stripped.
          tmp_root = if File.directory?(target.to_s)
                       target.to_s
                     else
                       File.dirname(target.to_s).sub(/\.rb\z/, '')
                     end
          # Project root: the DISPATCHED kind's own project root when the
          # target's tmp root differs from the production 'test_file' tmp
          # root (probe copies, foreign incorporations — enumerating the
          # production tree there would both mis-report and mask the
          # intended empty/discovery error), else the production project
          # root (single-registration flow).
          prod_tmp = begin
            agent.resolve_path('test_file', '.', 'tmp').to_s
          rescue StandardError
            nil
          end
          proj_root =
            if prod_tmp && File.expand_path(tmp_root) == File.expand_path(prod_tmp)
              begin
                agent.resolve_path('test_file', '.', 'project').to_s
              rescue StandardError
                nil
              end
            else
              sibling = File.expand_path('../../test', tmp_root)
              File.directory?(sibling) ? sibling : nil
            end
          roots = [tmp_root, proj_root].compact.select { |r| File.directory?(r) }
          # Round 11 (python tier): suite scope also enumerates the kind's
          # python location root (python/test, legacy scout-rig home) when
          # the DISPATCHED kind declares one, so a whole-suite run covers
          # the Python tier too. Derived from the same agent surfaces as
          # the tmp/project pair; absent kind definitions (no agent, or a
          # probe copy without the root) contribute nothing.
          py_root =
            begin
              agent.resolve_path('test_file', '.', 'python').to_s
            rescue StandardError
              nil
            end
          roots << py_root if py_root && File.directory?(py_root)
          roots = roots.uniq
          raise ParameterException, 'run_test: no test directories found for suite scope' if roots.empty?

          files = roots.flat_map { |r| discover(r) }.sort.uniq
          raise ParameterException, 'run_test: no test files found for suite scope' if files.empty?

          wrap_result(scope, files.collect { |f| run_file(f, timeout_seconds: timeout || SUITE_TIMEOUT) }, target)
        else
          raise ParameterException, "run_test: unknown scope #{scope.inspect} (file, directory or suite)"
        end
      end

      private

      # Aggregate one per-file result list into the run_test return shape.
      def wrap_result(scope, results, target)
        passed = results.count { |r| r['passed'] }
        failed = results.count { |r| !r['passed'] && r['ran'] }
        not_run = results.count { |r| !r['ran'] }
        {'scope' => scope,
         'target' => target.to_s,
         'count' => results.length,
         'passed' => passed,
         'failed' => failed,
         'not_run' => not_run,
         'ok' => failed.zero? && not_run.zero? && passed == results.length,
         'results' => results}
      end

      # Fresh child process with the repo-conventional loader and the
      # TERM -> KILL timeout discipline. `pgroup: true`
      # makes the child its own process-group leader so the negative-pid
      # signal reaches the whole tree.
      def run_child(file, timeout_seconds:, agent: nil)
        loader = '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)'
        # Anchor contract (see ScoutCoder.child_checkout): the child loads
        # the workflow.rb of the project checkout that OWNS this test file.
        # `file` is the resolved absolute target; `agent` (when present,
        # supplied via run_for_agent) carries the engine-registered kind
        # roots, so the pinned-root fallback can identify a foreign project
        # that registered the kinds itself. The respond_to? guard keeps
        # direct TestFileSupport.run_file callers (no agent) working.
        pinned = agent.respond_to?(:path_kind_definition) ?
                   (agent.path_kind_definition('test_file') rescue nil) : nil
        pinned_root = pinned.is_a?(Hash) && pinned['roots'].is_a?(Hash) ?
                        pinned['roots']['tmp'] : nil
        checkout = if ScoutCoder.respond_to?(:child_checkout)
                     ScoutCoder.child_checkout(file: file, pinned_root: pinned_root)
                   else
                     ScoutCoder::PATH_KIND_ROOT
                   end

        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = Process.spawn(RbConfig.ruby, '-e', loader, file.to_s,
                            chdir: checkout.to_s, out: out_w, err: err_w,
                            pgroup: true)
        out_w.close
        err_w.close

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
        status = nil

        timed_out = false
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          break if status

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            timed_out = true
            status = term_group(pid)
            status = reap(pid) if status.nil?
            break
          end

          sleep 0.1
        end

        out = Thread.new { out_r.read }.value
        err = Thread.new { err_r.read }.value
        out_r.close
        err_r.close

        [out, err, status, timed_out, checkout]
      end

      # After term_group's KILL fallback the child is a zombie until reaped;
      # a short blocking wait collects it without erroring when it is gone.
      def reap(pid)
        Process.waitpid2(pid).last
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def term_group(pid)
        begin
          Process.kill('TERM', -pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        grace_end = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERM_GRACE
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return status if status
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > grace_end
            begin
              Process.kill('KILL', -pid)
            rescue Errno::ESRCH, Errno::EPERM
              nil
            end
            return nil
          end
          sleep 0.1
        end
      end
    end
  end
end
