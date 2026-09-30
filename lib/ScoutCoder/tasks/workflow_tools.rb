require 'json'

module ScoutCoder
  # Small task-inspection and execution surface for workflows available to Scout.
  # Keep this independent of WorkflowCoder: ScoutCoder jobs are resolved through
  # Workflow.require_workflow and run using the workflow's normal Step API.
  helper :managed_workflow do |workflow|
    raise ParameterException, 'workflow is required' if workflow.nil? || workflow.to_s.strip.empty?
    workflow.to_s == 'ScoutCoder' ? ScoutCoder : Workflow.require_workflow(workflow.to_s)
  end

  helper :managed_task do |workflow, task|
    wf = managed_workflow(workflow)
    name = task.to_s
    raise ParameterException, 'task is required' if name.strip.empty?
    raise ParameterException, "Task '#{name}' not found in workflow '#{workflow}'. Available: #{wf.tasks.keys.sort_by(&:to_s).join(', ')}" unless wf.tasks.include?(name.to_sym)
    [wf, wf.tasks[name.to_sym]]
  end

  helper :managed_inputs do |inputs|
    parsed = inputs.is_a?(String) ? JSON.parse(inputs) : (inputs || {})
    raise ParameterException, 'inputs must be a JSON object' unless parsed.is_a?(Hash)
    parsed.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
  end

  helper :describe_task_input do |input|
    name, type, description, default, options = input
    { name: name.to_s, type: type.to_s, description: description.to_s,
      default: default, required: !!(options && options[:required]) }
  end

  input :workflow, :string, 'Workflow name to inspect'
  task :list_tasks => :json do |workflow|
    wf = managed_workflow(workflow)
    wf.tasks.sort_by { |name, _task| name.to_s }.map do |name, task|
      { name: name.to_s, description: task.description.to_s, type: task.type.to_s,
        inputs: (task.inputs || []).map { |input| describe_task_input(input) } }
    end
  end

  input :workflow, :string, 'Workflow name'
  input :task, :string, 'Task name'
  task :task_inputs => :json do |workflow, task|
    wf, definition = managed_task(workflow, task)
    { workflow: wf.to_s, task: task.to_s, description: definition.description.to_s,
      result_type: definition.type.to_s,
      direct_inputs: (definition.inputs || []).map { |input| describe_task_input(input) },
      recursive_inputs: (definition.recursive_inputs || []).map { |input| describe_task_input(input) } }
  end

  input :workflow, :string, 'Workflow name'
  input :task, :string, 'Task name'
  input :inputs, :text, 'JSON object of task input names to values', {}
  input :clean, :boolean, 'Clean the job cache before execution', false
  task :run_task => :json do |workflow, task, inputs, clean|
    result = { workflow: workflow.to_s, task: task.to_s, inputs: {}, status: 'error',
               output: nil, job_path: nil, short_path: nil, cache_replay: nil, error: nil }
    begin
      wf, _definition = managed_task(workflow, task)
      provided = managed_inputs(inputs)
      result[:inputs] = provided.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value }
      step = wf.job(task.to_sym, nil, provided)
      result[:job_path] = step.path.to_s if step.respond_to?(:path)
      result[:short_path] = step.short_path.to_s if step.respond_to?(:short_path)
      previously_done = step.respond_to?(:done?) && step.done?
      step.clean if clean && step.respond_to?(:clean)
      previously_done = false if clean
      result[:cache_replay] = !!previously_done
      result[:output] = step.run
      info = step.info rescue {}
      result[:status] = (info[:status] || (step.done? ? 'done' : 'unknown')).to_s
    rescue Exception => error
      result[:error] = { class: error.class.name, message: error.message }
      begin
        result[:status] = step.info[:status].to_s if step && step.info[:status]
      rescue Exception
      end
    end
    result
  end

  input :workflow, :string, 'Workflow name'
  input :task, :string, 'Task name'
  input :inputs, :text, 'JSON object of task input names to values', {}
  task :job_info => :json do |workflow, task, inputs|
    wf, _definition = managed_task(workflow, task)
    step = wf.job(task.to_sym, nil, managed_inputs(inputs))
    info = step.info rescue {}
    { workflow: workflow.to_s, task: task.to_s, job_path: step.path.to_s,
      short_path: step.short_path.to_s,
      info_path: (step.info_file.to_s if step.respond_to?(:info_file)),
      status: (info[:status] || (step.done? ? 'done' : 'not_run')).to_s,
      time_started: info[:started], time_done: info[:done],
      messages: info[:messages] || [], exception: info[:exception] }
  end

  input :workflow, :string, 'Workflow name'
  input :task, :string, 'Task name'
  input :inputs, :text, 'JSON object of task input names to values', {}
  task :job_status => :json do |workflow, task, inputs|
    wf, _definition = managed_task(workflow, task)
    step = wf.job(task.to_sym, nil, managed_inputs(inputs))
    info = step.info rescue {}
    { workflow: workflow.to_s, task: task.to_s, job_path: step.path.to_s,
      short_path: step.short_path.to_s,
      status: (info[:status] || (step.done? ? 'done' : 'not_run')).to_s,
      running: (info[:status].to_s == 'running'),
      time_started: info[:started], time_done: info[:done],
      exception: info[:exception] }
  end

  # Create new authored task definitions under share/tasks. Keep this trusted
  # code interface with the tooling, not alongside the files it creates.
  input :task_name, :string, 'New task identifier (lowercase letters, digits and underscores; starts with a letter)'
  input :definition, :text, 'Ruby task DSL source: desc/input declarations and a task declaration matching task_name'
  task :define_task => :json do |task_name, definition|
    name = task_name.to_s
    unless name.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ParameterException, "Invalid task name '#{name}'; expected [a-z][a-z0-9_]*"
    end
    unless definition.is_a?(String) && !definition.strip.empty?
      raise ParameterException, 'definition must be non-empty Ruby source'
    end

    task_dir = File.realpath(File.expand_path('../../../share/tasks', __dir__))
    target = File.expand_path("#{name}.rb", task_dir)
    unless File.dirname(target) == task_dir && File.basename(target) == "#{name}.rb"
      raise ParameterException, 'Task path must remain directly within share/tasks'
    end
    if File.exist?(target) || File.symlink?(target)
      raise ParameterException, "Task file already exists: #{target}; refusing to overwrite"
    end

    declaration = /^\s*task\s+[:']?#{Regexp.escape(name)}(?:\s|=>|$)/
    unless definition.match?(declaration)
      raise ParameterException, "definition must declare task :#{name}"
    end

    source = "module ScoutCoder\n\n#{definition.rstrip}\n\nend\n"
    begin
      RubyVM::InstructionSequence.compile(source, target) if defined?(RubyVM::InstructionSequence)
      File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0644) { |file| file.write(source) }
    rescue SyntaxError => error
      raise ParameterException, "Invalid Ruby task definition: #{error.message}"
    rescue Errno::EEXIST
      raise ParameterException, "Task file already exists: #{target}; refusing to overwrite"
    end

    { task: name, path: target, bytes: source.bytesize,
      syntax_validated: !!defined?(RubyVM::InstructionSequence), overwritten: false }
  end
end
