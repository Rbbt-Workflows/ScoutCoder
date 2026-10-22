# The `python_task` path kind (round 11).
#
# Translates the legacy Python-task support (lib/ScoutCoder/python_task_support.rb
# and lib/ScoutCoder/tasks/python_task_tools.rb, both UNTOUCHED this round) into
# the agent Path-engine kind architecture, following lib/ScoutCoder/path_kinds/task.rb
# as the closest template. The legacy helpers that are worth keeping are REUSED
# through ScoutCoder::PythonTaskSupport (name validation, ast.parse syntax check,
# AST-based with_scout_import) so there are no second copies in this file; only
# what the kind architecture needs differently is implemented here.
#
# Binding conventions (research/path-kinds-round10-test-file-corrections.md):
#   - roots are declared as Scout Paths here; the engine pins every non-absolute
#     root to an absolute String at registration (path_pin_roots!)
#   - registration-time root resolution goes through the CURRENT workflow
#     (never hardcoded ScoutCoder - the round-9 trap)
#   - `.find(:current)`, never bare `.find`
#   - smoke = initialization-only, NEVER execution (canary-proven below)
#   - promote = one resource, declarative destination, engine moves it,
#     no post-move hooks, no-clobber default
#
# Engine-level semantics are documented in scout-ai
# doc/developer/PathEngine.md; see the aggregator header for load order
# (support + test_file load before any kind file).
module ScoutCoder
  PATH_KIND_PYTHON_TASK_DEFINITION = {
      'description' =>
      "Manage the #{target_workflow_name} Scout Python tasks (drafts in share/python_tasks, " \
        "promoted copies in python/tasks). " \
        'Virtual paths are relative to the kind root: a bare name such as greet_user, ' \
        'with NO .py suffix and no physical prefix (share/python_tasks/, python/tasks/). ' \
        'Never include the .rb suffix used by the Ruby kinds; this kind addresses ' \
        'Python sources.',

      'extension' => 'py',
      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      # Roots: share/python_tasks for drafts (the same `share/` draft-loading
      # convention area as the other kinds; nothing loads these automatically
      # - LiveWorkflow loads Ruby drafts only), and the target workflow's
      # python/tasks (the scout-rig directory convention) for promoted files.
      # Python drafts are NEVER auto-loaded: registration depends on the
      # workflow's own python/tasks discovery (see PROMOTE-THEN-WIRE below).
      'roots' => {
        'tmp' => Scout.share.python_tasks,
        'project' => Scout.python.tasks
      },

      # Generic CRUD restated explicitly (identical to the engine defaults) for
      # documentation value; validate/smoke/promote on top. 'patch' and 'test'
      # stay off: not implemented; the engine 'test' operation was removed
      # (round 9).
      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true, 'smoke' => true,
        'promote' => true
      },

      # -----------------------------------------------------------------
      # validate: pure static check, NO execution, NO import, NO
      # __pycache__. Four-arg hook; the engine has already resolved and
      # authorized :read on the path. Name pattern is checked first (the
      # same [a-z][a-z0-9_]* contract as the legacy authoring task), then
      # non-emptiness, then ast.parse syntax through the legacy helper
      # (fresh `python -c` child; it only parses, never imports), then a
      # static AST scan for scout.task(...) registration. The AST scan is
      # an intentionally cheap approximation: a scout.task(...) call
      # anywhere at module level satisfies it; it does not bind names or
      # run any code.
      # -----------------------------------------------------------------
      'validate' => lambda do |agent, path, location, args|
        resolve_kind = args['kind'] || 'python_task'
        target = agent.resolve_path(resolve_kind, path, location)
        errors, warnings = [], []
        # canonical warning suppressed by docstring at EITHER location

        name = File.basename(path.to_s)
        begin
          ScoutCoder::PythonTaskSupport.validate_name(name)
        rescue ArgumentError => e
          errors << e.message
        end

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'python_task', 'op' => 'validate',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        content = File.read(target.to_s)

        if content.strip.empty?
          errors << 'task source must be non-empty Python source'
        else
          begin
            ScoutCoder::PythonTaskSupport.validate_python_source(content, label: 'task source')
          rescue ArgumentError => e
            errors << e.message
          end
        end

        if errors.empty?
          unless ScoutCoder.path_kind_python_task_registers?(content)
            errors << 'no `scout.task(...)` registration found (static AST scan; author the function AND its scout.task registration)'
          end
          # Doc convention (warning only, both locations): Python tasks
          # carry their documentation in a module docstring; promoted files
          # may move it to README.md per project convention.
          if content !~ /\A\s*(?:#!.*\n|#.*\n)*\s*(?:from __future__ import[^\n]*\n\s*)*(?:r?'''|r?""")/
            warnings << 'no module docstring (convention: Python tasks carry their documentation in a module docstring; promoted tasks may move it to README.md per project convention)'
          end
        end

        {'ok' => errors.empty?, 'kind' => 'python_task', 'op' => 'validate',
         'path' => path, 'location' => location,
         'reasons' => errors, 'warnings' => warnings}
      end,

      # -----------------------------------------------------------------
      # smoke (round-11 contract, modeled on the task kind): smoke means
      # "the resource can be initialized/constructed/registered", NEVER
      # "it executes". For a Python task, initialization is exactly what
      # scout-rig's PythonWorkflow.load_directory does to register a
      # python/tasks directory: run the file with --scout-metadata (the
      # framework's own metadata runner; a plain child `python` process,
      # never an import) and register the declared tasks.
      #
      # In a FRESH process:
      #   1. load the current workflow (Workflow.require_workflow
      #      './workflow.rb' from the checkout root - the dynamic anchor,
      #      no workflow name hardcoded)
      #   2. build a Path-methoded draft directory from the DRAFT's OWN
      #      dirname (drafts live one per file at either kind root; the
      #      directory containing the draft IS the load_directory target)
      #   3. PythonWorkflow.load_directory(dir, 'ScoutCoderPythonSmoke')
      #      and assert the task registers
      #   4. construct the job Step with placeholder values for REQUIRED
      #      inputs only, derived from task_info (the Python metadata
      #      schema carries required flags and defaults - map_param sets
      #      options[:required] from the Python `required` and the default
      #      from the function signature default)
      #
      # NEVER executes the task body: job construction only. Proven by
      # the side-effect canary test (a task whose body writes a file if
      # executed; the file must never appear across every smoke run).
      #
      # TRUST BOUNDARY (same as the task kind): the fresh child loads
      # agent-authored Python and the checkout workflow with the invoking
      # user's privileges; there is NO OS sandbox.
      # -----------------------------------------------------------------
      'smoke' => lambda do |agent, path, location, args|
        resolve_kind = args['kind'] || 'python_task'
        target = agent.resolve_path(resolve_kind, path, location)
        root_dir = agent.path_kind_definition(resolve_kind).fetch('project_root', nil) ||
                   File.expand_path('../../../..', agent.path_kind_definition(resolve_kind).fetch('roots').fetch('project').to_s)
        name = File.basename(path.to_s, '.py')

        unless File.file?(target.to_s)
          raise ParameterException,
                "smoke: python_task '#{path}' failed at stage=check: target does not exist or is not a file: #{target}"
        end

        begin
          ScoutCoder::PythonTaskSupport.validate_name(name)
        rescue ArgumentError => e
          raise ParameterException, "smoke: python_task '#{path}' failed at stage=check: #{e.message}"
        end

        content = File.read(target.to_s)
        begin
          ScoutCoder::PythonTaskSupport.validate_python_source(content, label: 'task source')
        rescue ArgumentError => e
          raise ParameterException,
                "smoke: python_task '#{path}' failed at stage=check: #{e.message}"
        end

        script = <<~RUBY
          require 'scout-ai'
          #$stdout.sync = true
          draft = #{target.to_s.inspect}
          placeholders = {}
          stage = 'load'
          begin
            workflow = Workflow.require_workflow './workflow.rb'
            stage = 'register'
            # Path-methoded directory containing the draft: load_directory
            # requires a Scout Path (glob_names) - a plain String raises
            # NoMethodError (round-11 baseline gotcha, registration/d1).
            draft_dir = Path.setup(File.dirname(draft))
            loaded = PythonWorkflow.load_directory(draft_dir, 'ScoutCoderPythonSmoke')
            # REGISTRATION NAME = the FUNCTION name, not the file name:
            # python.rb L29 derives the *file* task_name but task.rb L142
            # registers under meta['name'] (the python function name).
            # Metadata names drive the check; read_python_metadata can return
            # an empty payload ('' -> JSON::ParserError in scout-rig 0.2.6) for
            # a file that registers nothing, so treat that as "no names" rather
            # than leaking the parser error through the smoke report.
            begin
              metas = PythonWorkflow.read_python_metadata(draft)
              metas = [metas] unless Array === metas
              meta_names = metas.collect { |m| m['name'] }.compact
            rescue JSON::ParserError, RuntimeError
              meta_names = []
            end
            registered = meta_names.select { |n| loaded.tasks.include?(n.to_sym) }
            raise "task not registered after load_directory (file \#{File.basename(draft)}: expected \#{meta_names.inspect}, registered \#{loaded.tasks.keys.inspect})" if registered.empty?
            task_name = registered.first.to_sym
            stage = 'derive'
            info = loaded.task_info(task_name)
            (info[:inputs] || []).each_with_index do |iname, i|
              itype = (info[:input_types] || [])[i]
              idefault = (info[:input_defaults] || [])[i]
              ioptions = (info[:input_options] || [])[i]
              ioptions = nil unless Hash === ioptions
              # Same requiredness rule as the task kind: explicit
              # required:true, or no default and not explicitly optional.
              required = ioptions && ioptions[:required] == true
              required ||= idefault.nil? && !(ioptions && ioptions[:required] == false)
              next unless required
              select_options = nil
              if ioptions && ioptions[:select_options]
                declared = ioptions[:select_options]
                select_options = Hash === declared ? declared.values.flatten : declared
              end
              placeholders[iname] =
                if select_options && select_options.any?
                  select_options.first.to_s
                elsif itype == :integer
                  0
                elsif itype == :float
                  0.0
                elsif itype == :boolean
                  true
                elsif itype == :array || itype.to_s.end_with?('_array')
                  []
                else
                  'smoke-placeholder'
                end
            end
            stage = 'construct'
            job = loaded.job(task_name, nil, placeholders)
            raise "job object is not a Step: \#{job.class}" unless Step === job
            required_names = placeholders.keys.collect(&:to_s).sort
            puts "SMOKE_OK stage=\#{stage} task=\#{task_name} required=\#{required_names.inspect} job=\#{job.class} executed=false"
          rescue Exception => e
            message = e.message.to_s.lines.first.to_s.strip
            puts "SMOKE_FAIL stage=\#{stage} \#{e.class}: \#{message}"
            exit 1
          end
        RUBY

        # PYTHONDONTWRITEBYTECODE: the metadata runner must never leave a
        # __pycache__ beside the draft (asserted by the probes/tests).
        env = { 'PYTHONDONTWRITEBYTECODE' => '1' }
        out, err, status = Open3.capture3(env, RbConfig.ruby, '-e', script,
                                          chdir: root_dir)
        if status.success?
          {'ok' => true, 'kind' => 'python_task', 'op' => 'smoke',
           'path' => path, 'location' => location, 'task' => name,
           'stage' => 'construct', 'executed' => false,
           'exit_status' => status.exitstatus,
           'stdout' => out, 'stderr' => err}
        else
          fail_line = (out.lines + err.lines).collect(&:strip).reverse.find do |line|
            line.start_with?('SMOKE_FAIL')
          end
          detail = fail_line ? "failed at #{fail_line.sub('SMOKE_FAIL ', '')}" :
                               "failed with exit #{status.exitstatus}: #{(out + err).strip[0, 300]}"
          raise ParameterException,
                "smoke: python_task '#{path}' (task #{name}) #{detail}"
        end
      end,

      # Declarative promotion destination (a Callable would be REJECTED by
      # the engine). The engine authorizes both endpoints and performs the
      # move itself; no-clobber unless overwrite:true, and a refused move
      # leaves the source intact.
      #
      # PROMOTE-THEN-WIRE GAP (README follow-up deferred): promotion is a
      # FILE MOVE, not registration. Nothing under python/tasks is loaded
      # automatically by this kind: registration depends on the workflow's
      # OWN python/tasks discovery (PythonWorkflow#load_python_tasks /
      # python_task_dir, seeded by Scout.python.tasks.find_all from the
      # checkout - confirmed live in the round-11 baseline). A promoted
      # Python task is inert until that discovery runs (workflow reload,
      # or an explicit PythonWorkflow.load_directory / python_task call),
      # and its documentation moves to README per project convention.
      # No promotion_post_move hook is registered (round-10 step 6
      # contract): the engine moves exactly one resource and the agent
      # owns any paired-test coordination.
      'promotion_destination' => 'project'
  }.freeze

  module_function

  # Static AST detection of a scout.task(...) registration. Runs a small
  # `python -c` child (never an import, never a __pycache__ - the same
  # child-process discipline as PythonTaskSupport.validate_python_source)
  # and reports whether any module-level Call node targets the name
  # `task` on the name `scout` (scout.task(f), scout.task(f, ...) or
  # scout.task(*fs)).
  def path_kind_python_task_registers?(source)
    python = ENV.fetch('PYTHON', 'python3')
    script = <<~'PYTHON'
      import ast, sys, json
      tree = ast.parse(sys.stdin.read())
      found = False
      for node in tree.body:
          if not isinstance(node, ast.Expr) or not isinstance(node.value, ast.Call):
              continue
          func = node.value.func
          if isinstance(func, ast.Attribute) and func.attr == 'task' and \
             isinstance(func.value, ast.Name) and func.value.id == 'scout':
              found = True
      print(json.dumps({'scout_task_call': found}))
    PYTHON
    stdout, _stderr, status = Open3.capture3(python, '-c', script, stdin_data: source)
    return false unless status.success?
    JSON.parse(stdout).fetch('scout_task_call', false)
  rescue Errno::ENOENT, JSON::ParserError
    false
  end
end
