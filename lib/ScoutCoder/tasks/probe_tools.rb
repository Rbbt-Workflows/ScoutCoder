require_relative '../probe_support'
require_relative '../path_kinds'

module ScoutCoder
  desc 'Run one probe Ruby snippet in a fresh UNSANDBOXED child process (trusted code, caller authority, ScoutCoder-only, for investigating the Scout framework). When source is given: save, syntax-check, then execute, reporting saved/syntax/execution as independent outcomes. When path only: re-execute the existing probe.'
  input :path, :string, 'Virtual probe path (bare name, no .rb suffix, no share/probes/ prefix)'
  input :source, :text, 'OPTIONAL complete probe source; when given the probe is written/overwritten, syntax-checked and executed in one call', nil
  input :timeout_seconds, :integer, 'Per-probe timeout in seconds', ScoutCoder::ProbeSupport::PROBE_TIMEOUT
  task :run_probe => :json do |path, source, timeout_seconds|
    begin
      raise ParameterException, "Missing required input 'path'" if path.nil? || path.to_s.empty?

      agent = ProbeSupport.agent_standin

      if source && !source.to_s.empty?
        args = {}
        args['timeout_seconds'] = timeout_seconds unless timeout_seconds.nil?
        ProbeSupport.write_and_run(agent, path, 'tmp', source, args)
      else
        target = agent.resolve_path('probe', path, 'tmp')
        raise ParameterException, "run_probe: probe '#{path}' does not exist or is not a file: #{target}" unless File.file?(target.to_s)

        args = {}
        args['timeout_seconds'] = timeout_seconds unless timeout_seconds.nil?
        ProbeSupport.run_for_agent(agent, target, args)
      end
    rescue ParameterException
      raise
    rescue StandardError => error
      raise ParameterException, "run_probe failed: #{error.class}: #{error.message}"
    end
  end
  export_exec :run_probe
end
