require 'json'
require 'ripper'

module ScoutCoder
  # Keep export choice resolution and emitted DSL source directly testable
  # without invoking define_task's filesystem-writing behavior.
  module TaskDefinition
    module_function

    # Resolve the export declaration for a generated task. `export_mode` is a
    # deprecated compatibility alias: it applies only when export_type is
    # omitted and must agree with export_type when both are supplied.
    def resolve_export_type(export_type, export_mode = nil)
      export_type = export_mode if export_type.nil?
      export_type = export_type.to_s unless export_type.nil?
      return nil if export_type.nil?
      unless %w[export export_exec].include?(export_type)
        raise ParameterException, "define_task validation failed [export_type]: expected 'export', 'export_exec' or omission, got #{export_type.inspect}"
      end
      if export_mode && export_type != export_mode.to_s
        raise ParameterException, "define_task validation failed [export_type]: export_type #{export_type.inspect} conflicts with export_mode #{export_mode.to_s.inspect}"
      end
      export_type
    end

    def source(name, definition, export_type)
      source = "module ScoutCoder\n\n#{definition.rstrip}\n"
      source += "\n#{export_type} :#{name}\n" if export_type
      source + "\nend\n"
    end
  end

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

  # Create new authored task definitions under share/tasks. Keep this trusted
  # code interface with the tooling, not alongside the files it creates.
  # Promoted task: documentation lives in README.md (## define_task), not desc.
  input :task_name, :string, 'New task identifier (lowercase letters, digits and underscores; starts with a letter)', nil, required: true
  input :definition, :text, 'Ruby task DSL source: desc/input declarations and a task declaration matching task_name', nil, required: true
  input :export_type, :string, 'Optionally export the generated task with export or export_exec (none to omit)', 'export'
  task :define_task => :json do |task_name, definition, export_type|
    name = task_name.to_s
    unless name.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ParameterException, "define_task validation failed [task_name]: invalid task name '#{name}'; expected [a-z][a-z0-9_]*"
    end
    export_type = nil if export_type == 'none'
    unless export_type.nil? || %w[export export_exec].include?(export_type)
      raise ParameterException, "define_task validation failed [export_type]: expected 'export', 'export_exec' or 'none', got #{export_type.inspect}"
    end
    unless definition.is_a?(String) && !definition.strip.empty?
      raise ParameterException, 'define_task validation failed [source]: definition must be non-empty Ruby source'
    end

    task_dir = begin
      File.realpath(File.expand_path('../../../share/tasks', __dir__))
    rescue SystemCallError => error
      raise ParameterException, "define_task validation failed [task_directory]: cannot resolve share/tasks: #{error.message}"
    end
    target = File.expand_path("#{name}.rb", task_dir)
    unless File.dirname(target) == task_dir && File.basename(target) == "#{name}.rb"
      raise ParameterException, 'define_task validation failed [path]: task file must remain directly within share/tasks'
    end
    if File.exist?(target) || File.symlink?(target)
      raise ParameterException, "define_task validation failed [no_overwrite]: task file already exists: #{target}; refusing to overwrite"
    end

    # Inspect Ruby tokens rather than matching raw text, so comments and string
    # literals cannot masquerade as a task declaration.
    tokens = Ripper.lex(definition).reject do |_position, type, _text, _state|
      %i[on_sp on_ignored_nl on_nl on_comment].include?(type)
    end
    declared = tokens.each_with_index.any? do |(_position, type, text, _state), index|
      next false unless type == :on_ident && text == 'task'
      previous = tokens[index - 1]
      next false if previous && %i[on_period on_op].include?(previous[1]) && %w[. &.].include?(previous[2])
      symbol, identifier = tokens[index + 1, 2]
      symbol && identifier && symbol[1] == :on_symbeg && symbol[2] == ':' &&
        identifier[1] == :on_ident && identifier[2] == name
    end
    unless declared
      raise ParameterException, "define_task validation failed [declaration]: source must contain a Ruby task :#{name} declaration (not only a comment or string)"
    end

    source = TaskDefinition.source(name, definition, export_type)
    unless defined?(RubyVM::InstructionSequence)
      raise ParameterException, 'define_task validation failed [syntax]: RubyVM::InstructionSequence is unavailable; refusing to write unchecked Ruby source'
    end
    begin
      RubyVM::InstructionSequence.compile(source, target)
    rescue SyntaxError => error
      raise ParameterException, "define_task validation failed [syntax]: #{error.message}"
    end

    begin
      # EXCL is the final no-overwrite guard against a concurrent creator.
      File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0644) { |file| file.write(source) }
    rescue Errno::EEXIST
      raise ParameterException, "define_task validation failed [no_overwrite]: task file already exists: #{target}; refusing to overwrite"
    rescue SystemCallError => error
      raise ParameterException, "define_task write failed [write]: #{error.message}"
    end

    workflow_file = File.expand_path('../../../workflow.rb', __dir__)
    begin
      reloaded_workflow = Workflow.require_workflow(workflow_file, update: true)
    rescue StandardError, ScriptError => error
      raise ParameterException,
            "define_task reload failed after writing candidate #{target}; " \
            "workflow entrypoint #{workflow_file} raised #{error.class}: #{error.message}"
    end

    unless reloaded_workflow && reloaded_workflow.tasks.include?(name.to_sym)
      registered = reloaded_workflow && reloaded_workflow.tasks
      available = registered ? registered.keys.sort_by(&:to_s).join(', ') : '(workflow unavailable)'
      raise ParameterException,
            "define_task registration failed after writing candidate #{target}; " \
            "workflow #{workflow_file} did not register :#{name}. Available tasks: #{available}"
    end

    { task: name, path: target, bytes: source.bytesize,
      validation: { task_name: 'passed', source: 'passed', declaration: 'passed',
                    syntax: 'passed', load: 'passed', registration: 'passed',
                    inspection: 'passed', registration_validation: 'passed' },
      written: true, overwritten: false }
  end

  export :define_task, :list_tasks, :task_inputs, :task_code, :task_dependencies
  export_exec :run_task, :job_info, :job_status
end
