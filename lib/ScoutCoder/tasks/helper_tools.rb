require_relative '../helper_test_support'

module ScoutCoder
  # Promoted tasks: documentation lives in README.md, not desc.
  input :workflow, :string, 'Workflow whose authored helper test is being created', 'ScoutCoder'
  input :helper_name, :string, 'Existing ScoutCoder-authored workflow helper name'
  input :test_source, :text, 'Ruby test source; define a disposable task that invokes the helper within a Step'
  task :author_helper_test => :json do |workflow, helper_name, test_source|
    begin
      HelperTestSupport.write_test(HelperTestSupport.workflow_root(workflow), helper_name, test_source)
    rescue StandardError => error
      raise ParameterException, "author_helper_test failed: #{error.message}"
    end
  end
  export_exec :author_helper_test

  input :workflow, :string, 'Workflow whose authored helper test should run', 'ScoutCoder'
  input :helper_name, :string, 'ScoutCoder-authored helper name whose test should run'
  input :timeout_seconds, :integer, 'Maximum test process runtime in seconds', HelperTestSupport::DEFAULT_TIMEOUT
  task :run_helper_test => :json do |workflow, helper_name, timeout_seconds|
    begin
      HelperTestSupport.run_test(HelperTestSupport.workflow_root(workflow), helper_name, timeout_seconds: timeout_seconds)
    rescue StandardError => error
      raise ParameterException, "run_helper_test failed: #{error.message}"
    end
  end
  export_exec :run_helper_test

  input :helper_name, :string, 'New helper identifier (lowercase letters, digits and underscores; starts with a letter)', nil, required: true
  input :definition, :text, 'Ruby source containing a matching helper declaration', nil, required: true
  input :workflow, :string, 'Workflow whose share/helpers directory receives the helper', 'ScoutCoder'
  task :define_helper => :json do |helper_name, definition, workflow|
    begin
      name = HelperTestSupport.validate_helper_name(helper_name)
    rescue ArgumentError => error
      raise ParameterException, "define_helper validation failed [helper_name]: #{error.message}"
    end
    unless definition.is_a?(String) && !definition.strip.empty?
      raise ParameterException, 'define_helper validation failed [source]: definition must be non-empty Ruby source'
    end

    target_workflow = managed_workflow(workflow)
    project_root = File.expand_path(target_workflow.libdir.to_s)
    raise ParameterException, "define_helper validation failed [workflow]: workflow '#{target_workflow}' has no checkout libdir" if target_workflow.libdir.nil?
    helper_dir = HelperTestSupport.safe_child_path(project_root, 'share', 'helpers')
    FileUtils.mkdir_p(helper_dir)
    helper_dir = File.realpath(helper_dir)
    target = File.expand_path("#{name}.rb", helper_dir)
    unless File.dirname(target) == helper_dir && File.basename(target) == "#{name}.rb"
      raise ParameterException, 'define_helper validation failed [path]: helper file must remain directly within share/helpers'
    end
    if File.exist?(target) || File.symlink?(target)
      raise ParameterException, "define_helper validation failed [no_overwrite]: helper file already exists: #{target}; refusing to overwrite"
    end

    source = "module #{target_workflow}\n\n#{definition.rstrip}\n\nend\n"
    unless defined?(RubyVM::InstructionSequence)
      raise ParameterException, 'define_helper validation failed [syntax]: RubyVM::InstructionSequence is unavailable; refusing to write unchecked Ruby source'
    end
    begin
      RubyVM::InstructionSequence.compile(source, target)
    rescue SyntaxError => error
      raise ParameterException, "define_helper validation failed [syntax]: #{error.message}"
    end
    unless definition.match?(/\bhelper\s+:#{Regexp.escape(name)}\b/)
      raise ParameterException, "define_helper validation failed [declaration]: source must contain helper :#{name}"
    end

    begin
      File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0644) { |file| file.write(source) }
    rescue Errno::EEXIST
      raise ParameterException, "define_helper validation failed [no_overwrite]: helper file already exists: #{target}; refusing to overwrite"
    rescue SystemCallError => error
      raise ParameterException, "define_helper write failed [write]: #{error.message}"
    end

    workflow_file = File.join(project_root, 'workflow.rb')
    begin
      reloaded_workflow = Workflow.workflows.find do |candidate|
        candidate.respond_to?(:libdir) && candidate.libdir &&
          File.expand_path(candidate.libdir.to_s) == File.expand_path(project_root)
      end
      unless reloaded_workflow
        raise LoadError, "workflow entrypoint not found: #{workflow_file}" unless File.file?(workflow_file)
        require 'pathname'
        reloaded_workflow = Dir.chdir(project_root) { Workflow.require_workflow_file(Pathname.new(workflow_file)) }
        reloaded_workflow = Workflow.workflows.find do |candidate|
          candidate.respond_to?(:libdir) && candidate.libdir &&
            File.expand_path(candidate.libdir.to_s) == File.expand_path(project_root)
        end || reloaded_workflow
      end
      reloaded_workflow.load_live_files! if reloaded_workflow.respond_to?(:load_live_files!)
    rescue StandardError, ScriptError => error
      raise ParameterException,
            "define_helper reload failed after writing candidate #{target}; " \
            "workflow entrypoint #{workflow_file} raised #{error.class}: #{error.message}"
    end

    registered = reloaded_workflow && reloaded_workflow.helpers && reloaded_workflow.helpers[name.to_sym]
    unless registered
      available = reloaded_workflow && reloaded_workflow.helpers ? reloaded_workflow.helpers.keys.sort_by(&:to_s).join(', ') : '(workflow unavailable)'
      raise ParameterException,
            "define_helper registration failed after writing candidate #{target}; " \
            "workflow #{workflow_file} did not register helper :#{name}. Available helpers: #{available}"
    end

    { helper: name, workflow: target_workflow.to_s, path: target, bytes: source.bytesize,
      validation: { helper_name: 'passed', source: 'passed', declaration: 'passed', syntax: 'passed',
                    load: 'passed', registration: 'passed' },
      written: true, overwritten: false }
  end
  export_exec :define_helper
end
