require_relative '../task_test_support'

module ScoutCoder
desc "Create a test for an existing ScoutCoder-authored task

Inputs: `task_name` and `test_source`. The paired test is written following the
task's source location: `share/test/task/<task_name>.rb` for tasks authored
under `share/tasks`, or `test/ScoutCoder/tasks/test_<file>.rb` for tasks in
`lib/ScoutCoder/tasks`. The task source must exist, the name must match
`[a-z][a-z0-9_]*`, the Ruby source is syntax-checked before writing, and an
existing test file is never overwritten. The test is not run during creation;
use `run_task_test` to execute it in a fresh Ruby process."
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

desc "Run an authored task test in a fresh Ruby process

Inputs: `task_name` and positive `timeout_seconds` (default 120). The runner
starts a fresh Ruby process, loads the current `workflow.rb` (including every
authored task file), and executes the paired test. The pairing mirrors
`author_task_test`: `share/test/task/<task_name>.rb` for tasks under
`share/tasks`, `test/ScoutCoder/tasks/test_<file>.rb` for tasks in
`lib/ScoutCoder/tasks`. Returns pass/fail, exit status, standard output and
standard error, timeout status, and the invocation details. A fresh Ruby
process loads current source but does not clear persistent Scout job caches;
tests should explicitly clean jobs where freshness matters."
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
