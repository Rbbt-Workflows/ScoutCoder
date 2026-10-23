# Shared runner for the `probe` path kind and the `run_probe` ScoutCoder
# task (round 12, from the outcome-C engine-contract investigation —
# tmp/notes/round12-engine-contract.md).
#
# ONE runner, two entry surfaces (mirroring TestFileSupport):
#   * the custom path operation `run` on the probe kind
#     (operations table in lib/ScoutCoder/path_kinds/probe.rb)
#   * the ScoutCoder task `run_probe` (lib/ScoutCoder/tasks/probe_tools.rb)
#
# CONTRACT: unsandboxed execution of TRUSTED code. A probe is a Ruby
# snippet for investigating the Scout framework itself; the fresh child
# process runs it with the invoking user's privileges. There is NO OS
# sandbox and no bwrap — that is the point: probes may exercise Scout
# naturally, including loading a workflow that imports files outside any
# Workspace sandbox grant (the motivating case). Expose this runner only
# to agents that may already execute trusted Ruby in this checkout.
#
# Child discipline (identical to TestFileSupport.run_child):
#   fresh Ruby child; preloads the OWNING checkout's workflow.rb (the
#   same anchor contract: ScoutCoder.child_checkout — PATH_KIND_PROJECT_ROOT
#   override, owner-of-the-resolved-file marker climb, pinned kind root,
#   structural PATH_KIND_ROOT fallback) before `load`ing the probe;
#   process-group + TERM/10s-grace/KILL; per-probe timeout 1..3600
#   (default 120).
#
# Syntax gate BEFORE execution: RubyVM::AbstractSyntaxTree.parse (the
# same in-process AST mechanism the task/python_task kinds use; the
# EntityDefinitionSupport.compile! precedent uses Ripper.sexp — either is
# AST-only, zero side effects). A syntax failure means the probe is
# saved-but-not-executed and is reported as such, never raised past the
# caller as a raw error.
#
# Failure normalization (round-12 surprise 3): non-Scout exceptions from
# handlers escape the agent tool wrapper raw, so every failure path here
# returns a structured envelope or raises a Scout ParameterException —
# never a raw Ruby exception.
require 'fileutils'
require 'open3'
require 'rbconfig'

module ScoutCoder
  module ProbeSupport
    PROBE_TIMEOUT = 120
    TERM_GRACE = 10
    MIN_TIMEOUT = 1
    MAX_TIMEOUT = 3600

    class << self
      # A minimal agent stand-in exposing exactly resolve_path for the
      # probe kind, so the workflow task can drive the same dispatch path
      # the engine uses without a live LLM agent (the TestFileSupport
      # precedent).
      def agent_standin
        agent = Object.new
        agent.define_singleton_method(:resolve_path) do |kind, path, location|
          raise ParameterException, "Unknown path kind: #{kind}" unless kind.to_s == 'probe'
          root = Scout.share.probes
          root = Path.setup(root.to_s) unless Path === root
          Path.setup(File.join(root.find(:current).to_s, path.to_s)).set_extension('rb')
        end
        agent
      end

      # ------------------------------------------------------------------
      # Entry for both surfaces: run one probe file.
      #
      #   agent   : the engine agent (or the agent stand-in) supplying
      #             resolve_path for the probe kind — used only for the
      #             child-checkout anchor's pinned-root fallback.
      #   target  : the RESOLVED absolute probe path.
      #   args    : {'timeout_seconds' => Integer} (optional)
      #
      # Returns a result Hash (never raises on probe failure):
      #   'kind' 'op' 'path' 'timeout_seconds' 'runner'
      #   'workflow_loaded'  -> the checkout whose workflow.rb the child
      #                         preloaded (anchor contract)
      #   'exit_class'       -> 'completed' | 'raised' | 'timeout'
      #   'exit_status'      -> Integer or nil (timeout)
      #   'duration_seconds' -> Float
      #   'stdout' 'stderr'  -> captured streams
      # ------------------------------------------------------------------
      def run_for_agent(agent, target, args)
        timeout = normalize_timeout(args['timeout_seconds'])
        saved_kind = Thread.current[:scoutcoder_probe_kind]
        Thread.current[:scoutcoder_probe_kind] =
          (args['kind'] || saved_kind || dispatched_kind_name(agent, target))
        begin
          run_for_agent_with_kind(agent, target, args, timeout)
        ensure
          Thread.current[:scoutcoder_probe_kind] = saved_kind
        end
      end

      def dispatched_kind_name(agent, target)
        return 'probe' unless agent.respond_to?(:path_kind_definition)
        kind_for_target(agent, target)
      end

      def run_for_agent_with_kind(agent, target, args, timeout)
        checkout = child_checkout_for(target, agent)

        loader = '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)'

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        out, err, status, timed_out = run_child(target.to_s, loader, checkout, timeout.to_i)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        exit_class =
          if timed_out || status.nil?
            'timeout'
          elsif status.success?
            'completed'
          else
            'raised'
          end

        {'kind' => 'probe', 'op' => 'run',
         'path' => File.basename(target.to_s, '.rb'),
         'target' => target.to_s,
         'workflow_loaded' => checkout.to_s,
         'timeout_seconds' => timeout,
         'exit_class' => exit_class,
         'exit_status' => status ? status.exitstatus : nil,
         'duration_seconds' => (duration * 10).round / 10.0,
         'runner' => "ruby -e <loader> #{File.basename(target.to_s)}",
         'stdout' => out,
         'stderr' => err}
      rescue ParameterException
        raise
      rescue StandardError => e
        # Failure normalization: a runner-side infrastructure error is a
        # Scout parameter error, never a raw exception through the tool
        # wrapper (round-12 surprise 3).
        raise ParameterException, "run_probe failed: #{e.class}: #{e.message}"
      end

      # Syntax gate: AST-only parse, never executes. Returns the message
      # String on failure, nil when the source parses.
      def syntax_error_in(source)
        RubyVM::AbstractSyntaxTree.parse(source)
        nil
      rescue SyntaxError => e
        e.message.to_s.lines.first.to_s.strip
      end

      # Validate a caller-supplied timeout against the declared bounds;
      # returns the Integer (default PROBE_TIMEOUT) or raises.
      def normalize_timeout(value)
        return PROBE_TIMEOUT if value.nil?
        n = begin
          Integer(value)
        rescue ArgumentError, TypeError
          nil
        end
        if n.nil?
          raise ParameterException, "timeout_seconds must be an integer (#{MIN_TIMEOUT}..#{MAX_TIMEOUT}): #{value.inspect}"
        end
        unless (MIN_TIMEOUT..MAX_TIMEOUT).cover?(n)
          raise ParameterException, "timeout_seconds must be between #{MIN_TIMEOUT} and #{MAX_TIMEOUT} seconds: #{n}"
        end
        n
      end

      # ------------------------------------------------------------------
      # Custom-operation dispatch (the outcome-C channel). The engine has
      # already resolved and :read-authorized the target; `args` carries
      # the remaining custom-operation inputs ('source',
      # 'timeout_seconds'). With `source`: save first (never reverted on
      # failure), syntax-check, then execute, reporting saved/syntax/
      # execution as INDEPENDENT outcomes. Without: re-execute the
      # existing probe, reporting the execution outcome in the same shape.
      # ------------------------------------------------------------------
      def dispatch(agent, target, args)
        source = args['source']
        if source && !source.to_s.empty?
          path = File.basename(target.to_s, '.rb')
          # The dispatched-kind thread-local is set by the operation
          # wrapper BEFORE dispatch; args['kind'] is absent there (the
          # engine's installed callable deletes it), present only on the
          # task surface and direct calls. The wrapper does NOT know the
          # dispatched kind either (path_dispatch strips it), so when no
          # hint is present the write derives the kind from the
          # ENGINE-RESOLVED target the wrapper received — the sandbox-copy
          # regime (differently named kind with its own pinned root) then
          # writes into its own tree, exactly like the resolve hook would.
          kind = (Thread.current[:scoutcoder_probe_kind] ||
                  args['kind'] ||
                  kind_for_target(agent, target)).to_s
          kind = 'probe' unless agent.respond_to?(:path_kind_definition) &&
                               (agent.path_kind_definition(kind) rescue nil)
          write_and_run(agent, path, 'tmp', source, args.merge('kind' => kind))
        else
          execution = run_for_agent(agent, target, args)
          # Path-only re-run: same independent-outcome shape as a
          # write-and-run (saved/syntax not applicable; the file already
          # exists and was syntax-gated at write time).
          execution.merge('executed' => execution['exit_class'] != 'timeout')
        end
      end

      # ------------------------------------------------------------------
      # Create-and-run (the outcome-C channel): when the caller supplies
      # `source`, save it to the probe file FIRST (a runtime failure never
      # reverts or deletes the saved source), syntax-check it, then
      # execute — reporting saved / syntax / execution as INDEPENDENT
      # outcomes.
      # ------------------------------------------------------------------
      # Derive the DISPATCHED kind from the thread-local the operation
      # wrapper sets (the engine strips 'kind' from args before calling
      # the implementation — path_install_custom_tools' callable deletes
      # it). Falls back to args['kind'] (task surface, direct calls) and
      # 'probe'. A differently-named sandbox copy (the regression suite's
      # probe_kind!) then writes into ITS OWN pinned root, exactly the
      # round-11 convention of the test_file resolve/list hooks.
      def dispatched_kind(agent, args)
        candidate = (Thread.current[:scoutcoder_probe_kind] ||
                     args['kind'] || 'probe').to_s
        return candidate if agent.respond_to?(:path_kind_definition) &&
                            (agent.path_kind_definition(candidate) rescue nil)
        'probe'
      end

      # The engine strips 'kind' from args before invoking a :full custom
      # handler, so the thread-local above is the only channel that names
      # the DISPATCHED kind there. When it is unset AND args carries no
      # 'kind' (task surface on a real agent), derive the kind from the
      # resolved target's containing pinned root — first registered kind
      # wins, so the production 'probe' registration precedes any later
      # sandbox copy.
      def kind_for_target(agent, target)
        return 'probe' unless agent.respond_to?(:path_kind_registry)
        agent.path_kind_registry.keys.find do |candidate|
          roots = (agent.path_kind_definition(candidate).fetch('roots', {}) rescue nil)
          next false if roots.nil?
          root = roots['tmp']
          next false if root.nil?
          root = root.to_s.start_with?('/') ? root.to_s : root.find(:current).to_s
          target.to_s.start_with?(root + '/')
        end || 'probe'
      end

      def write_and_run(agent, path, location, source, args)
        timeout = normalize_timeout(args['timeout_seconds'])

        target = agent.resolve_path(dispatched_kind(agent, args), path, location)

        FileUtils.mkdir_p(File.dirname(target.to_s))
        File.write(target.to_s, source)
        saved = {'saved' => true, 'target' => target.to_s}

        syntax = syntax_error_in(source)
        if syntax
          return {'kind' => 'probe', 'op' => 'run', 'path' => path,
                  'location' => location}.merge(saved)
                     .merge('syntax_ok' => false, 'syntax_error' => syntax,
                            'executed' => false,
                            'execution' => {'exit_class' => 'skipped_syntax_error',
                                            'stdout' => '', 'stderr' => '',
                                            'exit_status' => nil})
        end

        execution = run_for_agent(agent, target, args)
        {'kind' => 'probe', 'op' => 'run', 'path' => path,
         'location' => location}.merge(saved)
            .merge('syntax_ok' => true, 'executed' => true, 'execution' => execution)
      rescue ParameterException
        raise
      rescue StandardError => e
        raise ParameterException, "run_probe failed: #{e.class}: #{e.message}"
      end

      private

      # Anchor contract (see ScoutCoder.child_checkout in
      # path_kinds/test_file.rb): the child preloads the workflow.rb of
      # the project checkout that OWNS the resolved probe file.
      def child_checkout_for(target, agent, resolve_kind = nil)
        resolve_kind = dispatched_kind(agent, 'kind' => resolve_kind) if resolve_kind
        pinned = agent.respond_to?(:path_kind_definition) ?
                   (agent.path_kind_definition(resolve_kind || 'probe') rescue nil) : nil
        pinned_root = pinned.is_a?(Hash) && pinned['roots'].is_a?(Hash) ?
                        pinned['roots']['tmp'] : nil
        # A probe kind copy may carry an explicit project_root (the smoke
        # convention, task.rb): the child MUST chdir there so its
        # `require './workflow'` resolves in the REAL checkout even when
        # the kind roots point at a sandbox (the regression suite).
        explicit = pinned.is_a?(Hash) ? pinned['project_root'] : nil
        return Path.setup(explicit.to_s) if explicit && File.directory?(explicit.to_s)
        if ScoutCoder.respond_to?(:child_checkout)
          ScoutCoder.child_checkout(file: target, pinned_root: pinned_root)
        else
          ScoutCoder::PATH_KIND_ROOT
        end
      end

      # Fresh child, process-group + TERM/grace/KILL (the
      # TestFileSupport.run_child discipline, restated for the probe
      # runner because the loader line differs).
      def run_child(file, loader, checkout, timeout_seconds)
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

        [out, err, status, timed_out]
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

      def reap(pid)
        Process.waitpid2(pid).last
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end
  end
end
