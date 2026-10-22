require_relative '../test_file_support'
require_relative '../path_kinds'

module ScoutCoder
  # Promoted tasks: documentation lives in README.md (## run_test), not desc.
  input :path, :path, 'Virtual test_file path (tmp-side spelling, e.g. task/greet_user, integration/round_trip, or "." for the suite root)'
  input :scope, :select, 'file, directory or suite', 'file', select_options: %w[file directory suite]
  input :location, :select, 'Location of the test files', 'tmp', select_options: %w[tmp project]
  input :timeout_seconds, :integer, 'Per-file timeout in seconds', ScoutCoder::TestFileSupport::FILE_TIMEOUT
  task :run_test => :json do |path, scope, location, timeout_seconds|
    begin
      raise ParameterException, "Missing required input 'path'" if path.nil? || path.to_s.empty?

      agent = TestFileSupport.agent_standin
      target = agent.resolve_path('test_file', path, location || 'tmp')

      args = {'scope' => scope || 'file'}
      args['timeout_seconds'] = timeout_seconds unless timeout_seconds.nil?
      TestFileSupport.run_for_agent(agent, target, args)
    rescue StandardError => error
      raise ParameterException, "run_test failed: #{error.message}"
    end
  end
  export_exec :run_test
end
