require 'json'

module ScoutCoder

  # Small task-inspection and execution surface for workflows available to Scout.
  # Keep this independent of WorkflowCoder: ScoutCoder jobs are resolved through
  # Workflow.require_workflow and run using the workflow's normal Step API.
  helper :managed_workflow do |workflow|
    raise ParameterException, 'workflow is required' if workflow.nil? || workflow.to_s.strip.empty?
    return ScoutCoder if workflow.to_s == 'ScoutCoder'
    loaded = Workflow.workflows.find { |candidate| candidate.to_s == workflow.to_s }
    return loaded if loaded

    # A workflow object may already be registered under a namespace-qualified
    # name while callers use its checkout's short directory name. Prefer the
    # existing checkout before asking Workflow to autoload by constant name.
    candidate_path = File.expand_path(workflow.to_s)
    if !File.exist?(candidate_path)
      project_root = File.expand_path('../../..', __dir__)
      local_candidate = File.join(project_root, 'tmp', 'workflows', workflow.to_s)
      candidate_path = local_candidate if File.directory?(local_candidate)
    end
    workflow_file = File.directory?(candidate_path) ? File.join(candidate_path, 'workflow.rb') : candidate_path
    if File.file?(workflow_file)
      require 'pathname'
      candidate_root = File.dirname(workflow_file)
      loaded_from_root = Workflow.workflows.find do |candidate|
        candidate.respond_to?(:libdir) && candidate.libdir && candidate_root == File.expand_path(candidate.libdir.to_s)
      end
      return loaded_from_root if loaded_from_root
      return Workflow.require_workflow_file(Pathname.new(workflow_file))
    end
    loaded = Workflow.workflows.find { |candidate| candidate.to_s == workflow.to_s }
    return loaded if loaded
    Workflow.require_workflow(workflow.to_s)
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

  helper :task_source_location do |callable|
    location = callable.source_location if callable.respond_to?(:source_location)
    if location && location.length >= 2
      { path: location[0].to_s, line: location[1] }
    else
      { path: nil, line: nil }
    end
  end

  helper :task_dependency_metadata do |definition|
    if definition.respond_to?(:deps)
      (definition.deps || []).map do |workflow, task_name, options, block, _original_args|
        if block
          { kind: 'dynamic', static: false, source: task_source_location(block) }
        else
          { kind: 'static', static: true,
            workflow: (workflow.name.to_s if workflow && workflow.respond_to?(:name)),
            task: (task_name.to_s if task_name), options: options || {} }
        end
      end
    else
      []
    end
  end

  input :workflow, :string, 'Workflow name to inspect'
  task :list_tasks => :json do |workflow|
    wf = managed_workflow(workflow)
    wf.tasks.sort_by { |name, _task| name.to_s }.map do |name, definition|
      dependencies = task_dependency_metadata(definition)
      { name: name.to_s, description: definition.description.to_s,
        type: definition.type.to_s,
        inputs: (definition.inputs || []).map { |input| describe_task_input(input) },
        source: task_source_location(definition),
        dependencies: {
          static_declarations: dependencies.select { |dependency| dependency[:static] },
          dynamic_block_present: dependencies.any? { |dependency| dependency[:kind] == 'dynamic' },
          supported: definition.respond_to?(:deps)
        } }
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
  task :task_code => :json do |workflow, task|
    wf, definition = managed_task(workflow, task)
    source = task_source_location(definition)
    path = source[:path]
    content = nil
    unavailable_reason = nil
    if path && File.file?(path)
      begin
        content = File.read(path)
      rescue StandardError => error
        unavailable_reason = "source file could not be read: #{error.message}"
      end
    else
      unavailable_reason = 'source file location is unavailable or does not identify a file'
    end
    { workflow: wf.to_s, task: task.to_s, source_path: path,
      definition_line: source[:line], text_scope: (content ? 'entire_file' : nil),
      source_text: content, unavailable_reason: unavailable_reason }
  end

  input :workflow, :string, 'Workflow name'
  input :task, :string, 'Task name'
  task :task_dependencies => :json do |workflow, task|
    wf, definition = managed_task(workflow, task)
    dependencies = task_dependency_metadata(definition)
    dynamic = dependencies.select { |dependency| dependency[:kind] == 'dynamic' }
    { workflow: wf.to_s, task: task.to_s,
      static_declarations: dependencies.select { |dependency| dependency[:static] },
      dynamic_dependency_block_present: !dynamic.empty?, dynamic_blocks: dynamic,
      dynamic_list_is_complete: false,
      unsupported: !definition.respond_to?(:deps) }
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
    rescue StandardError => error
      result[:error] = { class: error.class.name, message: error.message }
      begin
        result[:status] = step.info[:status].to_s if step && step.info[:status]
      rescue StandardError
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

  export :list_tasks, :task_inputs, :task_code, :task_dependencies
  export :task_inputs, :task_code, :task_dependencies
  export_exec :run_task, :job_info, :job_status
end
