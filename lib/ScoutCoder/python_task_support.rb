require 'fileutils'
require 'open3'
require 'json'

module ScoutCoder
  module PythonTaskSupport
    module_function

    NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/

    def project_root
      File.expand_path('../..', __dir__)
    end

    def validate_name(name)
      value = name.to_s
      raise ArgumentError, "invalid task name '#{value}'; expected [a-z][a-z0-9_]*" unless value.match?(NAME_PATTERN)
      value
    end

    def source_paths(root, name)
      name = validate_name(name)
      [File.join(root, 'python', 'tasks', "#{name}.py"),
       File.join(root, 'python', 'test', "test_#{name}.py")]
    end

    # Validate Python source without importing the source or creating
    # __pycache__ files. Task authoring may add the Scout import envelope first.
    def validate_python_source(source, label: 'Python source')
      raise ArgumentError, "#{label} must be non-empty Python source" unless source.is_a?(String) && !source.strip.empty?
      python = ENV.fetch('PYTHON', 'python3')
      script = 'import ast, sys; ast.parse(sys.stdin.read())'
      _stdout, stderr, status = Open3.capture3(python, '-c', script, stdin_data: source)
      return true if status.success?
      detail = stderr.to_s.strip
      raise ArgumentError, "#{label} has invalid Python syntax#{detail.empty? ? '' : ": #{detail}"}"
    rescue Errno::ENOENT => error
      raise ArgumentError, "cannot validate #{label}: Python interpreter '#{python}' is unavailable (#{error.message})"
    end

    def task_directory(root)
      File.join(File.realpath(root), 'python', 'tasks')
    end

    # The Scout import is framework plumbing. Keep Python function declarations
    # and scout.task registrations in authored source so task signatures and
    # task selection remain explicit. AST placement preserves module docstrings
    # and `from __future__` imports, which must precede ordinary imports.
    def with_scout_import(source)
      python = ENV.fetch('PYTHON', 'python3')
      script = <<~'PYTHON'
        import ast, json, sys
        tree = ast.parse(sys.stdin.read())
        has_scout = any(
            isinstance(node, ast.Import) and any(
                alias.name == 'scout' and alias.asname in (None, 'scout') for alias in node.names
            )
            for node in tree.body
        )
        after = 0
        for index, node in enumerate(tree.body):
            is_docstring = (index == 0 and isinstance(node, ast.Expr) and
                            isinstance(getattr(node, 'value', None), (ast.Str, ast.Constant)) and
                            isinstance(getattr(node.value, 's', getattr(node.value, 'value', None)), str))
            is_future = isinstance(node, ast.ImportFrom) and node.module == '__future__'
            if is_docstring or is_future:
                after = max(after, node.end_lineno)
        print(json.dumps({'has_scout': has_scout, 'after': after}))
      PYTHON
      stdout, stderr, status = Open3.capture3(python, '-c', script, stdin_data: source)
      raise ArgumentError, "cannot inspect Python task source: #{stderr.to_s.strip}" unless status.success?
      metadata = JSON.parse(stdout)
      return source if metadata['has_scout']

      lines = source.lines
      lines.insert(metadata.fetch('after'), "import scout\n")
      lines.join
    rescue Errno::ENOENT => error
      raise ArgumentError, "cannot inspect Python task source: Python interpreter '#{python}' is unavailable (#{error.message})"
    end

    # Reject symlinked parent components before creating or opening a generated
    # file. Checking only the final filename is insufficient: mkdir/open would
    # follow a symlink in (for example) python/tasks to a location outside the
    # workflow checkout.
    def ensure_safe_parent!(root, relative_parent)
      root = File.realpath(root)
      parent = File.expand_path(relative_parent, root)
      unless parent.start_with?(root + File::SEPARATOR)
        raise ArgumentError, 'Python file parent must remain within the workflow root'
      end

      current = root
      relative_parent.split(File::SEPARATOR).reject(&:empty?).each do |component|
        current = File.join(current, component)
        raise ArgumentError, "symlinked Python file parent is not allowed: #{current}" if File.symlink?(current)
        next unless File.exist?(current)
        unless File.directory?(current) && File.realpath(current).start_with?(root + File::SEPARATOR)
          raise ArgumentError, "Python file parent must be a directory within the workflow root: #{current}"
        end
      end
      true
    end

    # Ask scout-rig's actual runner for metadata rather than attempting to
    # reimplement function/decorator discovery from Python's AST.
    def metadata(root, task_name, target)
      validate_python_source(File.read(target), label: 'task source')
      rig_python = File.expand_path('~/git/scout-rig/python')
      python = ENV.fetch('PYTHON', 'python3')
      env = { 'PYTHONPATH' => ([rig_python, ENV['PYTHONPATH']].compact.reject(&:empty?).join(File::PATH_SEPARATOR)) }
      stdout, stderr, status = Open3.capture3(env, python, target, '--scout-metadata', chdir: root)
      unless status.success?
        raise ArgumentError, "Python metadata validation failed (#{status.exitstatus}): #{stderr.to_s.strip}"
      end
      parsed = JSON.parse(stdout)
      raise ArgumentError, 'Python task source must register at least one function with scout.task' unless parsed.is_a?(Array) && !parsed.empty?
      parsed
    rescue JSON::ParserError => error
      raise ArgumentError, "Python metadata validation failed: expected JSON from --scout-metadata (#{error.message}); stderr: #{stderr.to_s.strip}"
    rescue Errno::ENOENT => error
      raise ArgumentError, "cannot inspect Python task metadata: #{error.message}"
    end

    def define_task(workflow, name, source)
      name = validate_name(name)
      root = workflow.libdir
      raise ArgumentError, "workflow '#{workflow}' has no checkout libdir" if root.nil? || root.to_s.empty?
      root = File.realpath(root.to_s)
      target = File.join(root, 'python', 'tasks', "#{name}.py")
      raise ArgumentError, 'task path must remain directly within python/tasks' unless File.dirname(target) == task_directory(root)
      ensure_safe_parent!(root, File.join('python', 'tasks'))
      raise ArgumentError, "Python task file already exists: #{target}; refusing to overwrite" if File.exist?(target) || File.symlink?(target)
      raise ArgumentError, 'task source must be non-empty Python source' unless source.is_a?(String) && !source.strip.empty?
      original_source = source
      source = with_scout_import(source)
      validate_python_source(source, label: 'task source')
      FileUtils.mkdir_p(File.dirname(target))
      ensure_safe_parent!(root, File.join('python', 'tasks'))
      File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0644) { |file| file.write(source) }
      begin
        metas = metadata(root, name, target)
        names = metas.map { |meta| meta['name'] || meta[:name] }.compact.map(&:to_s)
        raise ArgumentError, 'Python task metadata did not expose any named tasks' if names.empty?
        require 'pathname'
        reloaded = Dir.chdir(root) { Workflow.require_workflow_file(Pathname.new(File.join(root, 'workflow.rb'))) }
        missing = names.reject { |task| reloaded.tasks.include?(task.to_sym) }
        unless missing.empty?
          raise ArgumentError, "workflow reload did not register Python task(s): #{missing.join(', ')}"
        end
      rescue StandardError, ScriptError => error
        raise ArgumentError, "Python task candidate was written to #{target}, but metadata/reload validation failed: #{error.class}: #{error.message}"
      end
      { task: name, registered_tasks: names, workflow: workflow.to_s, path: target,
        bytes: source.bytesize, written: true, overwritten: false, framework_import_added: !source.equal?(original_source),
        validation: { name: 'passed', syntax: 'passed', metadata: 'passed', load: 'passed', registration: 'passed' } }
    rescue Errno::EEXIST
      raise ArgumentError, "Python task file already exists: #{target}; refusing to overwrite"
    end

    def write_test(root, name, source)
      name = validate_name(name)
      task_path, target = source_paths(root, name)
      root = File.realpath(root.to_s)
      ensure_safe_parent!(root, File.join('python', 'tasks'))
      ensure_safe_parent!(root, File.join('python', 'test'))
      raise ArgumentError, "Python task source does not exist: #{task_path}" unless File.file?(task_path) && !File.symlink?(task_path)
      validate_python_source(source, label: 'test source')
      FileUtils.mkdir_p(File.dirname(target))
      ensure_safe_parent!(root, File.join('python', 'test'))
      File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0644) { |file| file.write(source) }
      { task: name, path: target, bytes: source.bytesize, written: true, overwritten: false,
        syntax: 'passed', execution: 'not_run' }
    rescue Errno::EEXIST
      raise ArgumentError, "Python test already exists: #{target}; refusing to overwrite"
    end
  end
end
