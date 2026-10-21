# The `task` path kind (split out of path_kinds.rb in round 9).
# Behavior preserved from the pre-split definition; the aggregator
# lib/ScoutCoder/path_kinds.rb merges this constant into PATH_KINDS.
# See the aggregator header for the engine contract and load order
# (support + test_file load before any kind file).
module ScoutCoder
  PATH_KIND_TASK_DEFINITION = {
      'description' =>
      "Manage the #{target_workflow_name} Scout workflow tasks (drafts in share/tasks, " \
        "promoted copies in lib/#{target_workflow_name}/tasks)",

      'extension' => 'rb',
      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      # Roots are declared as Scout Paths here; the engine pins every
      # non-absolute root to an absolute String at registration
      # (path_pin_roots!, scout-ai path.rb:306).
      'roots' => {
        'tmp' => Scout.share.tasks,
        'project' => Scout.lib[target_workflow_name].tasks
      },

      #'resolve' => lambda do |agent,path,location|
      #  case location
      #  when 'tmp'
      #    Scout.share.tasks[path + '.rb']
      #  when 'project'
      #    Scout.lib[target_workflow_name].tasks[path + '.rb']
      #  end
      #end,

      # Generic CRUD restated explicitly (identical to the engine defaults)
      # for documentation value; the three operations this kind implements
      # beyond CRUD are switched on. 'patch' and 'test' stay off: not
      # implemented; the engine 'test' operation was removed (round 9).
      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true, 'smoke' => true,
        'promote' => true
      },

      # -----------------------------------------------------------------
      # validate: pure static check, NO execution. 4-arg hook; the engine
      # has already resolved and authorized :read on the task path.
      # -----------------------------------------------------------------
      'validate' => lambda do |agent, path, location, args|
        target = agent.resolve_path('task', path, location)
        errors, warnings = [], []

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'task', 'op' => 'validate',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        content = File.read(target.to_s)

        # Syntax check: in-process AST parse (chosen over a `ruby -c`
        # subprocess: same parser as the running interpreter, no process
        # spawn, no side effects).
        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          errors << "ruby syntax error: #{e.message}"
        end

        if errors.empty?
          # Shape: both locations load into the workflow namespace
          # (LiveWorkflow Kernel#load for drafts, require_relative from
          # workflow.rb for promoted files), so declarations must be
          # wrapped in the workflow module.
          unless content =~ /^\s*module\s+#{target_workflow_name}\b/
            errors << "no `module #{target_workflow_name}` wrapper (task files load into the #{target_workflow_name} workflow module)"
          end
          unless content =~ /^\s*task\s+:?['"]?\w+/
            errors << 'no `task :name => :type do ... end` declaration found'
          end
          # desc convention is location dependent: drafts under share/tasks
          # carry their documentation in a desc; promoted tasks move it to
          # README.md (document_task), so only the tmp location warns.
          if location.to_s == 'tmp' && content !~ /^\s*desc\s/
            warnings << 'no `desc` declaration (convention: draft tasks carry a desc while under share/tasks)'
          end
        end

        {'ok' => errors.empty?, 'kind' => 'task', 'op' => 'validate',
         'path' => path, 'location' => location,
         'reasons' => errors, 'warnings' => warnings}
      end,

      # -----------------------------------------------------------------
      # smoke (round 9 contract): smoke means "the resource can be
      # initialized/constructed/registered", NEVER "it executes
      # correctly".
      #
      # For a task: in a FRESH process, load the current workflow through
      # the dynamic anchor (Workflow.require_workflow './workflow.rb'
      # resolved from the checkout root; no workflow name is hardcoded),
      # resolve the task in the registry, derive placeholder values for
      # REQUIRED inputs only, and CONSTRUCT the job object. Success = a
      # Step job object exists; execution is never attempted and is NOT
      # required to work.
      #
      # Requiredness rule (documented decision; scout-gear has no
      # required_inputs helper — Workflow#task_info task/info.rb L66-90
      # exposes types/defaults/options only, and Task#job task.rb L75-87
      # enforces only an explicit options[:required]): an input is
      # REQUIRED when options[:required] == true OR (its default is nil
      # AND options[:required] is not explicitly false). Inputs with any
      # default are optional and are OMITTED entirely from construction.
      #
      # Placeholder values per input type: string/text/chat/tsv/file,
      # typeless and unknown types -> 'smoke-placeholder'; :integer -> 0;
      # :float -> 0.0; :boolean -> true; :array and *_array -> []; and
      # for :select inputs the FIRST declared option (read from
      # options[:select_options]; Hash values are flattened per
      # scout-ai tools/workflow.rb L61-64. The legacy positional-Array
      # form is NOT used: it crashes Task#job itself at task.rb L67 with
      # TypeError "no implicit conversion of Symbol into Integer", so a
      # select declared that way is genuinely unconstructible and fails
      # at stage=construct).
      #
      # dep-only and no-input tasks: Task#job does NOT execute
      # dependencies — task.rb L98 calls Task#dependencies
      # (task/dependencies.rb L1-L120), which CONSTRUCTS each dependency
      # as a job object via workflow.job (dependencies.rb L42) without
      # running it; Step construction performs no filesystem writes. A
      # task with no inputs derives nothing and constructs with an empty
      # input set (smoke = workflow loads + task resolves + job
      # constructs).
      #
      # TRUST BOUNDARY: this hook loads agent-authored Ruby (the draft
      # and the checkout workflow) in a fresh child process
      # (Open3.capture3, chdir PATH_KIND_ROOT). There is NO OS sandbox:
      # the loaded code runs with the invoking user's privileges inside
      # the child; the parent only parses its stdout/stderr.
      # -----------------------------------------------------------------
      'smoke' => lambda do |agent, path, location, args|
        resolve_kind = args['kind'] || 'task'
        target = agent.resolve_path(resolve_kind, path, location)
        # Fresh-process CWD: the PROJECT checkout root, so './workflow.rb'
        # resolves in the child even when the kind roots point at a sandbox
        # (tests/probes). Derived from the kind definition, never hardcoded.
        root_dir = agent.path_kind_definition(resolve_kind).fetch('project_root', nil) ||
                   File.expand_path('../../..', agent.path_kind_definition(resolve_kind).fetch('roots').fetch('project').to_s)
        name = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          raise ParameterException,
                "smoke: task '#{path}' failed at stage=check: target does not exist or is not a file: #{target}"
        end

        content = File.read(target.to_s)

        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          raise ParameterException,
                "smoke: task '#{path}' failed at stage=check: ruby syntax error: #{e.message}"
        end

        task_name = ScoutCoder.path_kind_task_name_in(content) || name

        script = <<~RUBY
          require 'scout-ai'
          \#$stdout.sync = true
          task_name = #{task_name.inspect}
          draft = #{target.to_s.inspect}
          placeholders = {}
          stage = 'load'
          begin
            workflow = Workflow.require_workflow './workflow.rb'
            # Draft under test: load explicitly AFTER the workflow so a draft
            # whose roots are not the checkout share/ tree is still exercised
            # (same trust boundary as LiveWorkflow loading share/ drafts).
            load draft
            stage = 'resolve'
            # (fresh-process load; agent-authored drafts execute here)
            task = workflow.tasks[task_name.to_sym]
            raise "task not registered after workflow load (\#{workflow.tasks.length} tasks registered)" unless task
            stage = 'derive'
            (task.inputs || []).each do |iname, itype, _idesc, idefault, ioptions|
              ioptions = nil unless Hash === ioptions
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
            job = task.job(nil, placeholders)
            raise "job object is not a Step: \#{job.class}" unless Step === job
            required_names = placeholders.keys.collect(&:to_s).sort
            puts "SMOKE_OK stage=\#{stage} task=\#{task_name} required=\#{required_names.inspect} job=\#{job.class} executed=false"
          rescue Exception => e
            message = e.message.to_s.lines.first.to_s.strip
            puts "SMOKE_FAIL stage=\#{stage} \#{e.class}: \#{message}"
            exit 1
          end
        RUBY

        out, err, status = Open3.capture3(RbConfig.ruby, '-e', script,
                                          chdir: root_dir)
        if status.success?
          {'ok' => true, 'kind' => 'task', 'op' => 'smoke',
           'path' => path, 'location' => location, 'task' => task_name,
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
                "smoke: task '#{path}' (task #{task_name}) #{detail}"
        end
      end,

      # Declarative promotion destination: a Callable would be REJECTED by
      # the engine (it would have to run before the destination is
      # authorized). The engine authorizes both endpoints and performs the
      # move itself.
      'promotion_destination' => 'project'

      # (Round 10, step 6: the paired-test RELOCATION hook is REMOVED.
      # Test files are first-class `test_file` kind resources that promote
      # themselves through the test_file kind's own promote path; the Path
      # engine promotes one resource at a time and ScoutCoder coordinates
      # related promotions. A source-kind promotion therefore moves ONLY
      # the source file. See research/path-kinds-round10 step-6 note.)
  }.freeze
end
