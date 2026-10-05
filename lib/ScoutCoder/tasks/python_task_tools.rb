require_relative '../python_task_support'

module ScoutCoder
  # Promoted tasks: documentation lives in README.md, not desc.
  input :task_name, :string, 'New Python task file name (lowercase letters, digits and underscores; starts with a letter)', nil, required: true
  input :python_source, :text, 'Python task source; the tool supplies only the top-level `import scout` when missing (functions, signatures and scout.task registrations remain authored)', nil, required: true
  input :workflow, :string, 'Workflow whose python/tasks directory receives the file', 'ScoutCoder'
  task :define_python_task => :json do |task_name, python_source, workflow|
    begin
      PythonTaskSupport.define_task(managed_workflow(workflow), task_name, python_source)
    rescue StandardError => error
      raise ParameterException, "define_python_task failed: #{error.message}"
    end
  end
  export_exec :define_python_task

  input :task_name, :string, 'Existing Python task file name'
  input :test_source, :text, 'Complete Python unittest source to create for the task'
  task :author_python_task_test => :json do |task_name, test_source|
    begin
      PythonTaskSupport.write_test(PythonTaskSupport.project_root, task_name, test_source)
    rescue StandardError => error
      raise ParameterException, "author_python_task_test failed: #{error.message}"
    end
  end
  export_exec :author_python_task_test
end
