# Path kinds for the scout-ai agent path engine (round 5).
#
# This file defines ScoutCoder::PATH_KINDS, the workflow-scoped constant the
# engine consumes on WHOLE-WORKFLOW incorporation: a `tool: ScoutCoder` chat
# line (no task token) makes LLM::Agent#ask call
# integrate_workflow_path_kinds(ScoutCoder), which discovers the constant via
# const_defined?(:PATH_KINDS, false) and registers every entry through
# register_path_kind (deep-copying each definition at the boundary, so the
# frozen constant below is safe to share). Task-level
# `tool: ScoutCoder <task>` lines never register path kinds.
#
# The "task" kind is the first REAL kind: it models ScoutCoder's own
# two-location task layout.
#   tmp     -> <checkout>/share/tasks           LiveWorkflow authoring drafts
#   project -> <checkout>/lib/ScoutCoder/tasks  promoted, shipped task files
#
# Engine contract verified against the live engine source
# /home/mvazque2/git/scout-ai/lib/scout/llm/agent/path.rb (HEAD 39ea79f plus
# the uncommitted path-engine change set; the drift is a registration-time
# operation-table refactor, hook dispatch unchanged):
#   - roots MUST be absolute; relative roots fail sandbox authorization;
#   - capabilities are normalized over DEFAULT_CAPABILITIES at registration;
#   - validate/test/smoke are kind-supplied Callables invoked by
#     path_kind_operation as implementation.call(agent, path, location, args)
#     AFTER the engine resolved and authorized :read on the target;
#   - promote is engine-controlled: "promotion_destination" must be
#     declarative (String location, or a Hash with "location" and optional
#     "path"); a Callable is structurally rejected. The engine authorizes
#     BOTH endpoints, enforces no-clobber unless args["overwrite"], performs
#     the move itself, then runs the optional "promotion_post_move" hook
#     with the authorized endpoints merged into args.
#
# ScoutCoder: the engine's in-source plugin example (the load_path_plugins
# comment in path.rb) still shows the validate hook arity as
# ->(path, content). That is stale: the dispatched contract is the 4-arg
# ->(agent, path, location, args) above. Round 4 flagged it; still open.

#
# Round 7 adds two more REAL kinds on the same two-location layout:
#   entity          share/entities            <-> lib/ScoutCoder/entity/<entity>.rb
#   entity_property share/entity_properties   <-> lib/ScoutCoder/entity/<entity>/<property>.rb
# Virtual paths for entity_property are NESTED (<entity>/<property>.rb) so the
# engine's path-preserving declarative promotion covers the whole kind with one
# destination (round-7 decision 2). Identifier TSVs (share/entity/*.tsv) are
# deliberately OUT of scope (decision 3). Project-side entity/property files are
# NOT loaded by workflow.rb today: promotion is a pure engine-controlled file
# move and lib-side wiring is a separate deliberate workflow.rb change
# (decision 6). Engine pin for round 7: path.rb md5 e50f4c12faa95d1f142bc81737210c97
# (scout-ai b504275).

require 'fileutils'
require 'open3'
require 'rbconfig'

module ScoutCoder

  # Checkout root anchored structurally: this file lives at
  # <checkout>/lib/ScoutCoder/path_kinds.rb, so the root is exactly two
  # levels up, and File.expand_path guarantees an absolute path.
  #
  # ScoutCoder: the Scout convention for a workflow anchoring its own
  # directory is Path.caller_lib_dir (scout-gear lib/scout/workflow.rb,
  # Workflow.extended), which walks up from the calling file until it finds
  # a directory containing a marker entry (lib, bin or README.md). For this
  # checkout it resolves to the same root, but it depends on marker files
  # rather than on the file layout, so the structural __dir__ anchor is
  # preferred here; there is no documented one-call helper for "checkout
  # root of the currently loading file" that does not depend on markers.
  PATH_KIND_ROOT = File.expand_path('../..', __dir__)

  # Hash form (not Array-of-Hashes): the keys ARE the kind names, so a
  # missing or typo'd "name" key cannot silently mis-register.
  PATH_KINDS = {
    'task' => {
      'description' =>
        'Scout workflow task files for ScoutCoder (drafts in share/tasks, ' \
        'promoted copies in lib/ScoutCoder/tasks)',

      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      # Roots MUST be absolute (relative roots fail sandbox authorization).
      'roots' => {
        'tmp' => File.join(PATH_KIND_ROOT, 'share', 'tasks'),
        'project' => File.join(PATH_KIND_ROOT, 'lib', 'ScoutCoder', 'tasks')
      },

      # Generic CRUD restated explicitly (identical to the engine defaults)
      # for documentation value; the four operations this kind implements
      # beyond CRUD are switched on. 'patch' stays off: not implemented.
      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true, 'test' => true, 'smoke' => true,
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
          # Shape: both locations load into the ScoutCoder namespace
          # (LiveWorkflow Kernel#load for drafts, require_relative from
          # workflow.rb for promoted files), so declarations must be
          # wrapped in the workflow module.
          unless content =~ /^\s*module\s+ScoutCoder\b/
            errors << 'no `module ScoutCoder` wrapper (task files load into the ScoutCoder workflow module)'
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
      # test: write the paired test file at the location-conventional path
      # and execute it in a FRESH ruby process following this repo's
      # run_task_test convention (lib/ScoutCoder/task_test_support.rb:
      # new process, cwd at the checkout root, load ./workflow, then load
      # the test file). The test loads the task file from its CURRENT
      # location. 4-arg hook.
      #
      # Round-5 scope: the caller (probe driver / agent) may supply the
      # test body as args['test_source']; the callback writes and executes
      # it, reporting exit status and captured output.
      #
      # KNOWN ENGINE-UNMEDIATED TRUST BOUNDARY (documented, by design; see
      # tmp/notes/round5-gaps.md item c): the paired-test locations are
      # OUTSIDE the kind roots (share/test/task, test/ScoutCoder/tasks).
      # The engine authorizes :read on the TASK file before this hook runs,
      # but this hook's own writes are trusted in-process plugin code the
      # engine cannot constrain.
      #
      # ScoutCoder: the built-in path_test tool schema (path_tool_definition
      # "test" branch) declares only kind/path/location with
      # additionalProperties false, so args['test_source'] reaches this hook
      # only through direct dispatch (path_test / path_kind_operation /
      # path_dispatch), never through the model-facing tool call; the
      # "may extend this schema" comment in the engine has no code path
      # consuming a kind "parameters" extension for validate/test.
      # -----------------------------------------------------------------
      'test' => lambda do |agent, path, location, args|
        target = agent.resolve_path('task', path, location)
        name = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'task', 'op' => 'test',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        test_file = ScoutCoder.path_kind_test_file(name, location)
        supplied = args['test_source']

        if supplied
          # Explicit body: the caller owns the content, so writing it (and
          # replacing a previous generated test) is the requested operation.
          FileUtils.mkdir_p(File.dirname(test_file))
          File.write(test_file, supplied)
          origin = 'supplied'
        elsif File.file?(test_file)
          # Existing paired test (hand-authored or from a previous run):
          # never clobber it without an explicit body.
          origin = 'existing'
        else
          FileUtils.mkdir_p(File.dirname(test_file))
          File.write(test_file,
                     ScoutCoder.path_kind_test_template(name, target.to_s, location))
          origin = 'generated'
        end

        loader = '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)'
        out, err, status = Open3.capture3(RbConfig.ruby, '-e', loader, test_file,
                                          chdir: PATH_KIND_ROOT)

        {'ok' => status.success?, 'kind' => 'task', 'op' => 'test',
         'path' => path, 'location' => location,
         'test_file' => test_file, 'test_source' => origin,
         'exit_status' => status.exitstatus,
         'stdout' => out, 'stderr' => err}
      end,

      # -----------------------------------------------------------------
      # smoke: SMOKE DEFINITION (round 5, deliberately narrower than the
      # round-4 probe, which also ran a clean job): an in-process syntax
      # check, then a FRESH process that requires the real workflow
      # (checkout workflow.rb, so LiveWorkflow live-loads every share/tasks
      # draft) and asserts the task is registered in ScoutCoder.tasks (the
      # workflow task registry; scout-gear Workflow::Definition#tasks).
      # No job execution, no inference. 4-arg hook.
      # -----------------------------------------------------------------
      'smoke' => lambda do |agent, path, location, args|
        target = agent.resolve_path('task', path, location)
        name = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'task', 'op' => 'smoke',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        content = File.read(target.to_s)

        errors = []
        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          errors << "ruby syntax error: #{e.message}"
        end

        task_name = ScoutCoder.path_kind_task_name_in(content) || name

        if errors.empty?
          script = <<~RUBY
            \#$LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
            require './workflow'
            task_name = #{task_name.inspect}
            unless ScoutCoder.tasks.include?(task_name.to_sym)
              abort("smoke: task not registered after workflow load: \#{task_name}")
            end
            puts "SMOKE_OK task=\#{task_name} registered_tasks=\#{ScoutCoder.tasks.length}"
          RUBY

          out, err, status = Open3.capture3(RbConfig.ruby, '-e', script,
                                            chdir: PATH_KIND_ROOT)
          errors << "fresh-process workflow load failed (exit #{status.exitstatus}): #{(err + out).strip}" unless status.success?
        else
          out = err = ''
          status = nil
        end

        {'ok' => errors.empty?, 'kind' => 'task', 'op' => 'smoke',
         'path' => path, 'location' => location, 'task' => task_name,
         'reasons' => errors,
         'exit_status' => status && status.exitstatus,
         'stdout' => out, 'stderr' => err}
      end,

      # Declarative promotion destination: a Callable would be REJECTED by
      # the engine (it would have to run before the destination is
      # authorized). The engine authorizes both endpoints and performs the
      # move itself.
      'promotion_destination' => 'project',

      # Optional post-move hook: relocate the PAIRED TEST FILE when it
      # exists. Runs AFTER the engine-controlled move of the task file; it
      # is never the writer of the task file itself. Receives the authorized
      # endpoints in args ('promotion_target', 'promotion_source_target',
      # 'overwrite'). Like the test hook, this writes OUTSIDE the kind roots
      # (same documented trust boundary).
      'promotion_post_move' => lambda do |agent, path, location, args|
        name = File.basename(path.to_s, '.rb')
        moved = nil

        if location.to_s == 'tmp'
          tmp_test = File.join(PATH_KIND_ROOT, 'share', 'test', 'task', "#{name}.rb")
          proj_test = File.join(PATH_KIND_ROOT, 'test', 'ScoutCoder', 'tasks', "test_#{name}.rb")
          if File.file?(tmp_test)
            if File.file?(proj_test) && ![true, 'true'].include?(args['overwrite'])
              return {'post_move' => 'skipped',
                      'reason' => "paired test already exists: #{proj_test}"}
            end
            FileUtils.mkdir_p(File.dirname(proj_test))
            FileUtils.mv(tmp_test, proj_test)
            moved = proj_test
          end
        end

        {'post_move' => 'ok', 'test_file_moved' => moved}
      end
    },
    # -------------------------------------------------------------------
    # Round 7: `entity` — Scout entity module files, one file per entity.
    #   tmp     -> <checkout>/share/entities                    LiveWorkflow authoring drafts
    #   project -> <checkout>/lib/ScoutCoder/entity            promoted files (NOT loaded by workflow.rb yet)
    # Virtual path: <entity>.rb ; the file must be a TOP-LEVEL module
    # `module <CamelCase(file)>` containing `extend Entity` (or
    # `extend EntityWorkflow`) plus the body — the shape LiveWorkflow's
    # Kernel#load executes (live.rb:33) and the shipped generators emit
    # (entity_tools.rb entity_source). NOT workflow-namespaced.
    # -------------------------------------------------------------------
    'entity' => {
      'description' =>
        'Scout entity module files for ScoutCoder (drafts in share/entities, ' \
        'promoted copies in lib/ScoutCoder/entity/<entity>.rb)',

      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      'roots' => {
        'tmp' => File.join(PATH_KIND_ROOT, 'share', 'entities'),
        'project' => File.join(PATH_KIND_ROOT, 'lib', 'ScoutCoder', 'entity')
      },

      'sandbox' => true,

      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true, 'test' => true, 'smoke' => true,
        'promote' => true
      },

      'validate' => lambda do |agent, path, location, args|
        target = agent.resolve_path('entity', path, location)
        errors, warnings = [], []

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'entity', 'op' => 'validate',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        content = File.read(target.to_s)

        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          errors << "ruby syntax error: #{e.message}"
        end

        if errors.empty?
          # live.rb Kernel#loads this file at TOP LEVEL, so the entity module
          # must be a top-level constant derived from the file name
          # (entity_tools.rb constant_name: snake_case -> CamelCase).
          expected = ScoutCoder.path_kind_entity_module_name(File.basename(path.to_s, '.rb'))
          declared = ScoutCoder.path_kind_top_level_module(content)
          unless declared == expected
            errors << "top-level module must be `#{expected}` (from file name); found #{declared ? "`#{declared}`" : 'none'}"
          end
          unless content =~ /^\s*extend\s+(Entity|EntityWorkflow)\s*$/
            errors << 'no `extend Entity` / `extend EntityWorkflow` declaration inside the module'
          end
          warnings << 'nested top-level modules found (an entity file should declare exactly one)' if ScoutCoder.path_kind_top_level_modules(content).length > 1
        end

        {'ok' => errors.empty?, 'kind' => 'entity', 'op' => 'validate',
         'path' => path, 'location' => location,
         'module' => expected, 'reasons' => errors, 'warnings' => warnings}
      end,

      'test' => lambda do |agent, path, location, args|
        target = agent.resolve_path('entity', path, location)
        name = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'entity', 'op' => 'test',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        test_file = ScoutCoder.path_kind_entity_test_file(name, location)
        supplied = args['test_source']

        if supplied
          FileUtils.mkdir_p(File.dirname(test_file))
          File.write(test_file, supplied)
          origin = 'supplied'
        elsif File.file?(test_file)
          origin = 'existing'
        else
          FileUtils.mkdir_p(File.dirname(test_file))
          File.write(test_file,
                     ScoutCoder.path_kind_entity_test_template(name, target.to_s, location))
          origin = 'generated'
        end

        loader = '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)'
        out, err, status = Open3.capture3(RbConfig.ruby, '-e', loader, test_file,
                                          chdir: PATH_KIND_ROOT)

        {'ok' => status.success?, 'kind' => 'entity', 'op' => 'test',
         'path' => path, 'location' => location,
         'test_file' => test_file, 'test_source' => origin,
         'exit_status' => status.exitstatus,
         'stdout' => out, 'stderr' => err}
      end,

      'smoke' => lambda do |agent, path, location, args|
        target = agent.resolve_path('entity', path, location)
        name = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'entity', 'op' => 'smoke',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        content = File.read(target.to_s)

        errors = []
        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          errors << "ruby syntax error: #{e.message}"
        end

        module_name = ScoutCoder.path_kind_entity_module_name(name)

        if errors.empty?
          script = <<~RUBY
            \#$LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
            require './workflow'
            module_name = #{module_name.inspect}
            mod = Object.const_get(module_name) rescue nil
            if mod.nil?
              abort("smoke: entity module not defined after workflow load: \#{module_name}")
            end
            unless Entity::MODULES.include?(mod)
              abort("smoke: entity module not registered in Entity::MODULES: \#{module_name}")
            end
            puts "SMOKE_OK entity=\#{module_name} modules=\#{Entity::MODULES.length}"
          RUBY

          out, err, status = Open3.capture3(RbConfig.ruby, '-e', script,
                                            chdir: PATH_KIND_ROOT)
          errors << "fresh-process workflow load failed (exit #{status.exitstatus}): #{(err + out).strip}" unless status.success?
        else
          out = err = ''
          status = nil
        end

        {'ok' => errors.empty?, 'kind' => 'entity', 'op' => 'smoke',
         'path' => path, 'location' => location, 'module' => module_name,
         'reasons' => errors,
         'exit_status' => status && status.exitstatus,
         'stdout' => out, 'stderr' => err}
      end,

      'promotion_destination' => 'project',

      'promotion_post_move' => lambda do |agent, path, location, args|
        name = File.basename(path.to_s, '.rb')
        moved = nil

        if location.to_s == 'tmp'
          tmp_test = File.join(PATH_KIND_ROOT, 'share', 'test', 'entity', "#{name}.rb")
          proj_test = File.join(PATH_KIND_ROOT, 'test', 'ScoutCoder', 'entity', "test_#{name}.rb")
          if File.file?(tmp_test)
            if File.file?(proj_test) && ![true, 'true'].include?(args['overwrite'])
              return {'post_move' => 'skipped',
                      'reason' => "paired test already exists: #{proj_test}"}
            end
            FileUtils.mkdir_p(File.dirname(proj_test))
            FileUtils.mv(tmp_test, proj_test)
            moved = proj_test
          end
        end

        {'post_move' => 'ok', 'test_file_moved' => moved}
      end
    },

    # -------------------------------------------------------------------
    # Round 7: `entity_property` — entity property files with NESTED
    # virtual paths <entity>/<property>.rb (one kind, decision 2).
    #   tmp     -> <checkout>/share/entity_properties/<entity>/<property>.rb
    #   project -> <checkout>/lib/ScoutCoder/entity/<entity>/<property>.rb
    # Shape: top-level `module <CamelCase(entity segment)>` with at least one
    # `property :name => :type do ... end` and NO extend line (the entity file
    # owns the extend) — entity_tools.rb property_source.
    # -------------------------------------------------------------------
    'entity_property' => {
      'description' =>
        'Scout entity property files for ScoutCoder, nested virtual paths ' \
        '<entity>/<property>.rb (drafts in share/entity_properties, promoted ' \
        'copies in lib/ScoutCoder/entity/<entity>/<property>.rb)',

      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      'roots' => {
        'tmp' => File.join(PATH_KIND_ROOT, 'share', 'entity_properties'),
        'project' => File.join(PATH_KIND_ROOT, 'lib', 'ScoutCoder', 'entity')
      },

      'sandbox' => true,

      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true, 'test' => true, 'smoke' => true,
        'promote' => true
      },

      'validate' => lambda do |agent, path, location, args|
        target = agent.resolve_path('entity_property', path, location)
        errors, warnings = [], []

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'entity_property', 'op' => 'validate',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        entity = path.to_s.split(File::SEPARATOR).first.to_s
        property = File.basename(path.to_s, '.rb')
        flat_path = entity == property || entity.empty? ||
                    path.to_s.count(File::SEPARATOR) < 1
        errors << "virtual path must be <entity>/<property>.rb, got #{path.inspect}" if flat_path

        content = File.read(target.to_s)

        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          errors << "ruby syntax error: #{e.message}"
        end

        if errors.empty?
          expected = ScoutCoder.path_kind_entity_module_name(entity)
          declared = ScoutCoder.path_kind_top_level_module(content)
          unless declared == expected
            errors << "top-level module must be `#{expected}` (from entity segment); found #{declared ? "`#{declared}`" : 'none'}"
          end
          if content =~ /^\s*extend\s+(Entity|EntityWorkflow)\s*$/
            errors << 'property file must NOT carry an extend line (the entity file owns the extend)'
          end
          unless content =~ /^\s*property\s+:(\w+)\s*(=>|\b)/
            errors << 'no `property :name => :type do ... end` declaration found'
          end
          warnings << "property file does not declare `property :#{property}` explicitly (may rely on other declarations)" unless content =~ /^\s*property\s+:(#{Regexp.escape(property)})\b/
        end

        {'ok' => errors.empty?, 'kind' => 'entity_property', 'op' => 'validate',
         'path' => path, 'location' => location,
         'entity' => entity, 'property' => property, 'module' => expected,
         'reasons' => errors, 'warnings' => warnings}
      end,

      'test' => lambda do |agent, path, location, args|
        target = agent.resolve_path('entity_property', path, location)
        entity = path.to_s.split(File::SEPARATOR).first.to_s
        property = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'entity_property', 'op' => 'test',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        test_file = ScoutCoder.path_kind_entity_property_test_file(entity, property, location)
        supplied = args['test_source']

        if supplied
          FileUtils.mkdir_p(File.dirname(test_file))
          File.write(test_file, supplied)
          origin = 'supplied'
        elsif File.file?(test_file)
          origin = 'existing'
        else
          FileUtils.mkdir_p(File.dirname(test_file))
          File.write(test_file,
                     ScoutCoder.path_kind_entity_property_test_template(entity, property, target.to_s, location))
          origin = 'generated'
        end

        loader = '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)'
        out, err, status = Open3.capture3(RbConfig.ruby, '-e', loader, test_file,
                                          chdir: PATH_KIND_ROOT)

        {'ok' => status.success?, 'kind' => 'entity_property', 'op' => 'test',
         'path' => path, 'location' => location,
         'test_file' => test_file, 'test_source' => origin,
         'exit_status' => status.exitstatus,
         'stdout' => out, 'stderr' => err}
      end,

      'smoke' => lambda do |agent, path, location, args|
        target = agent.resolve_path('entity_property', path, location)
        entity = path.to_s.split(File::SEPARATOR).first.to_s
        property = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'entity_property', 'op' => 'smoke',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        content = File.read(target.to_s)

        errors = []
        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          errors << "ruby syntax error: #{e.message}"
        end

        module_name = ScoutCoder.path_kind_entity_module_name(entity)

        if errors.empty?
          script = <<~RUBY
            \#$LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
            require './workflow'
            module_name = #{module_name.inspect}
            property = #{property.inspect}
            mod = Object.const_get(module_name) rescue nil
            if mod.nil?
              abort("smoke: entity module not defined after workflow load: \#{module_name}")
            end
            unless mod.properties.keys.map(&:to_s).include?(property)
              abort("smoke: property not registered on \#{module_name}: \#{property} (has \#{mod.properties.keys.map(&:to_s).inspect})")
            end
            # Real dispatch on a synthetic entity: the loaded property runs and
            # returns a value (exceptions abort with the surfaced message).
            begin
              receiver = mod.setup('smoke-id', module_name, {})
              value = receiver.send(property)
            rescue Exception => e
              abort("smoke: dispatch of :\#{property} on synthetic entity raised \#{e.class}: \#{e.message}")
            end
            puts "SMOKE_OK entity=\#{module_name} property=\#{property} value=\#{value.inspect}"
          RUBY

          out, err, status = Open3.capture3(RbConfig.ruby, '-e', script,
                                            chdir: PATH_KIND_ROOT)
          errors << "fresh-process workflow load failed (exit #{status.exitstatus}): #{(err + out).strip}" unless status.success?
        else
          out = err = ''
          status = nil
        end

        {'ok' => errors.empty?, 'kind' => 'entity_property', 'op' => 'smoke',
         'path' => path, 'location' => location,
         'entity' => entity, 'property' => property, 'module' => module_name,
         'reasons' => errors,
         'exit_status' => status && status.exitstatus,
         'stdout' => out, 'stderr' => err}
      end,

      'promotion_destination' => 'project',

      'promotion_post_move' => lambda do |agent, path, location, args|
        entity = path.to_s.split(File::SEPARATOR).first.to_s
        property = File.basename(path.to_s, '.rb')
        moved = nil

        if location.to_s == 'tmp'
          tmp_test = File.join(PATH_KIND_ROOT, 'share', 'test', 'entity_property', entity, "#{entity}.#{property}.rb")
          proj_test = File.join(PATH_KIND_ROOT, 'test', 'ScoutCoder', 'entity', "test_#{entity}_#{property}.rb")
          if File.file?(tmp_test)
            if File.file?(proj_test) && ![true, 'true'].include?(args['overwrite'])
              return {'post_move' => 'skipped',
                      'reason' => "paired test already exists: #{proj_test}"}
            end
            FileUtils.mkdir_p(File.dirname(proj_test))
            FileUtils.mv(tmp_test, proj_test)
            moved = proj_test
          end
        end

        {'post_move' => 'ok', 'test_file_moved' => moved}
      end
    }
  }.freeze

  # ---------------------------------------------------------------------
  # Kind helpers (plain module functions; no engine dependency)
  # ---------------------------------------------------------------------

  # First `task :name` (or `task 'name'`) declaration in a task source.
  def self.path_kind_task_name_in(source)
    source[/^\s*task\s+:(\w+)/, 1] || source[/^\s*task\s+'(\w+)'/, 1]
  end

  # Location-conventional paired-test path for a task file name, following
  # this repo's own convention (TaskTestSupport.test_source_path and the
  # author_task_test tool contract): share-side tests carry NO test_ prefix
  # (share/test/task/<name>.rb), promoted-side tests do
  # (test/ScoutCoder/tasks/test_<name>.rb). Nested project subdirectories
  # are flattened in round 5; revisit if the lifecycle round needs them.
  def self.path_kind_test_file(name, location)
    case location.to_s
    when 'tmp'
      File.join(PATH_KIND_ROOT, 'share', 'test', 'task', "#{name}.rb")
    when 'project'
      File.join(PATH_KIND_ROOT, 'test', 'ScoutCoder', 'tasks', "test_#{name}.rb")
    else
      raise ArgumentError, "unknown location for task kind test: #{location}"
    end
  end

  # Default paired-test harness used when the test hook finds neither a
  # supplied body nor an existing paired test. Assertions follow the
  # registration + desc convention for drafts; a promoted task has its desc
  # removed by convention, so the desc assertion is emitted only for the
  # tmp location.
  def self.path_kind_test_template(name, task_file, location)
    task_name = path_kind_task_name_in(File.read(task_file)) || name
    desc_test = if location.to_s == 'tmp'
                  <<~RUBY

                    def test_has_desc
                      task_name = #{task_name.inspect}
                      description = ScoutCoder.tasks[task_name.to_sym].description.to_s
                      refute_empty description, "task :\#{task_name} has no desc"
                    end
                  RUBY
                end

    <<~RUBY
      # Generated by the "task" path kind (path_test) for #{File.basename(task_file)}.
      # Repo pairing convention: share/tasks/<name>.rb <-> share/test/task/<name>.rb;
      # lib/ScoutCoder/tasks/<file>.rb <-> test/ScoutCoder/tasks/test_<file>.rb.
      require 'test/unit'
      \#$LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
      require './workflow'

      # Load the task file from its CURRENT location. A tmp draft was
      # already live-loaded by LiveWorkflow through workflow.rb, so this
      # Kernel#load re-declaration is idempotent (tasks reassign).
      load #{task_file.inspect}

      class TestTask_#{name} < Test::Unit::TestCase
        def test_registers
          task_name = #{task_name.inspect}
          assert ScoutCoder.tasks.include?(task_name.to_sym),
                 "task :\#{task_name} not registered after loading the task file"
        end
      #{desc_test}end
    RUBY
  end

  # ---------------------------------------------------------------------
  # Round-7 kind helpers (plain module functions; no engine dependency)
  # ---------------------------------------------------------------------

  # snake_case entity name -> top-level module constant, following the
  # generators' convention (entity_tools.rb constant_name).
  def self.path_kind_entity_module_name(entity)
    entity.to_s.split('_').collect(&:capitalize).join
  end

  # Top-level module names declared by a piece of Ruby source, in order.
  # Used for the shape checks: an entity file declares exactly one
  # top-level module; a property file declares the entity's module.
  def self.path_kind_top_level_modules(source)
    source.scan(/^module\s+([A-Z]\w*)\s*$/).flatten
  end

  # First top-level module name declared by the source, or nil.
  def self.path_kind_top_level_module(source)
    path_kind_top_level_modules(source).first
  end

  # Location-conventional paired-test path for an ENTITY file name.
  # Same pairing convention as the task kind, under the entity tree
  # (round-7 decision 6): share/test/entity/<name>.rb (tmp) and
  # test/ScoutCoder/entity/test_<name>.rb (project).
  def self.path_kind_entity_test_file(name, location)
    case location.to_s
    when 'tmp'
      File.join(PATH_KIND_ROOT, 'share', 'test', 'entity', "#{name}.rb")
    when 'project'
      File.join(PATH_KIND_ROOT, 'test', 'ScoutCoder', 'entity', "test_#{name}.rb")
    else
      raise ArgumentError, "unknown location for entity kind test: #{location}"
    end
  end

  # Default entity test harness: loads workflow.rb (so LiveWorkflow has
  # Kernel#loaded the draft), then asserts the module exists, is extended
  # as an Entity and registered in Entity::MODULES.
  def self.path_kind_entity_test_template(name, entity_file, location)
    module_name = path_kind_entity_module_name(name)

    <<~RUBY
      # Generated by the "entity" path kind (path_test) for #{File.basename(entity_file)}.
      # Repo pairing convention: share/entities/<name>.rb <-> share/test/entity/<name>.rb;
      # lib/ScoutCoder/entity/<name>.rb <-> test/ScoutCoder/entity/test_<name>.rb.
      require 'test/unit'
      $LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
      require './workflow'

      class TestEntity_#{name} < Test::Unit::TestCase
        def test_registered_as_entity
          module_name = #{module_name.inspect}
          assert Object.const_defined?(module_name),
                 "entity module \#{module_name} not defined after workflow load"
          mod = Object.const_get(module_name)
          assert Entity::MODULES.include?(mod),
                 "entity module \#{module_name} not registered in Entity::MODULES"
        end
      end
    RUBY
  end

  # Location-conventional paired-test path for a PROPERTY file
  # (<entity>/<property> virtual path). The project side flattens the
  # nested virtual path into one test_<entity>_<property>.rb file name.
  def self.path_kind_entity_property_test_file(entity, property, location)
    case location.to_s
    when 'tmp'
      File.join(PATH_KIND_ROOT, 'share', 'test', 'entity_property', entity, "#{entity}.#{property}.rb")
    when 'project'
      File.join(PATH_KIND_ROOT, 'test', 'ScoutCoder', 'entity', "test_#{entity}_#{property}.rb")
    else
      raise ArgumentError, "unknown location for entity_property kind test: #{location}"
    end
  end

  # Default property test harness: loads workflow.rb, then asserts the
  # property is registered on the entity module.
  def self.path_kind_entity_property_test_template(entity, property, property_file, location)
    module_name = path_kind_entity_module_name(entity)

    <<~RUBY
      # Generated by the "entity_property" path kind (path_test) for #{File.basename(property_file)}.
      # Repo pairing convention:
      #   share/entity_properties/<entity>/<property>.rb <-> share/test/entity_property/<entity>/<entity>.<property>.rb
      #   lib/ScoutCoder/entity/<entity>/<property>.rb <-> test/ScoutCoder/entity/test_<entity>_<property>.rb
      require 'test/unit'
      $LOAD_PATH.unshift(File.expand_path('lib', Dir.pwd))
      require './workflow'

      class TestEntityProperty_#{entity}_#{property} < Test::Unit::TestCase
        def test_property_registered
          module_name = #{module_name.inspect}
          property = #{property.inspect}
          assert Object.const_defined?(module_name),
                 "entity module \#{module_name} not defined after workflow load"
          mod = Object.const_get(module_name)
          assert mod.properties.keys.map(&:to_s).include?(property),
                 "property :\#{property} not registered on \#{module_name} " \\
                 "(has \#{mod.properties.keys.map(&:to_s).inspect})"
          # Real dispatch on a synthetic entity (single receiver, no
          # annotations needed), mirroring the entity_tools precedent
          # (test/ScoutCoder/tasks/test_entity_tools.rb): must not raise.
          receiver = mod.setup('smoke-id', #{module_name.inspect}, {})
          assert_nothing_raised do
            receiver.send(property)
          end
        end
      end
    RUBY
  end
end
