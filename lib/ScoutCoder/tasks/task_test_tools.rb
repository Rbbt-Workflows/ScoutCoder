require_relative '../task_test_support'

module ScoutCoder
  # Unimported task file (workflow.rb require commented out; README entries
  # removed in round 12). Successor: the test_file path kind + run_test.
  input :task_name, :string, 'Existing ScoutCoder-authored task name'
  input :test_source, :text, 'Ruby test source to create for the task'
  task :author_task_test => :json do |task_name, test_source|
    begin
      TaskTestSupport.write_test(TaskTestSupport.project_root, task_name, test_source)
    rescue StandardError => error
      raise ParameterException, "author_task_test failed: #{error.message}"
    end
  end
  export_exec :author_task_test

  input :task_name, :string, 'ScoutCoder-authored task name whose test should run'
  input :timeout_seconds, :integer, 'Maximum test process runtime in seconds', TaskTestSupport::DEFAULT_TIMEOUT
  task :run_task_test => :json do |task_name, timeout_seconds|
    begin
      TaskTestSupport.run_test(TaskTestSupport.project_root, task_name, timeout_seconds: timeout_seconds)
    rescue StandardError => error
      raise ParameterException, "run_task_test failed: #{error.message}"
    end
  end
  export_exec :run_task_test
end
