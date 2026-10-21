# The `entity` path kind (split out of path_kinds.rb in round 9).
# Behavior preserved from the pre-split definition; the aggregator
# lib/ScoutCoder/path_kinds.rb merges this constant into PATH_KINDS.
# See the aggregator header for the engine contract and load order
# (support + test_file load before any kind file).
module ScoutCoder

    # -------------------------------------------------------------------
    # Round 7: `entity` — Scout entity module files, one file per entity.
    #   tmp     -> <checkout>/share/entities                    LiveWorkflow authoring drafts
    #   project -> <checkout>/lib/<workflow>/entity            promoted files (NOT loaded by workflow.rb yet)
    # Virtual path: <entity>.rb ; the file must be a TOP-LEVEL module
    # `module <CamelCase(file)>` containing `extend Entity` (or
    # `extend EntityWorkflow`) plus the body — the shape LiveWorkflow's
    # Kernel#load executes (live.rb:33) and the shipped generators emit
    # (entity_tools.rb entity_source). NOT workflow-namespaced.
    # -------------------------------------------------------------------
  PATH_KIND_ENTITY_DEFINITION = {
      'description' =>
        "Scout entity module files for #{target_workflow_name} (drafts in share/entities, " \
        "promoted copies in lib/#{target_workflow_name}/entity/<entity>.rb)",

      'extension' => 'rb',
      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      'roots' => {
        'tmp' => Scout.share.entities,
        'project' => Scout.lib[target_workflow_name].entity
      },

      'sandbox' => true,

      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true, 'smoke' => true,
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

      # -----------------------------------------------------------------
      # smoke (round 9 contract): the entity module loads/resolves AND is
      # registered as an entity (Entity::MODULES). No dispatch of any
      # kind. Verified: this IS the round-5 behavior modulo the failure
      # envelope (registration assertions unchanged, fresh-process load
      # unchanged); the only round-9 change is that every failure is a
      # ParameterException carrying the stage instead of an ok:false
      # payload or an in-child abort message.
      #
      # TRUST BOUNDARY: loads agent-authored Ruby in a fresh child
      # process (Open3.capture3, chdir PATH_KIND_ROOT); no OS sandbox.
      # -----------------------------------------------------------------
      'smoke' => lambda do |agent, path, location, args|
        resolve_kind = args['kind'] || 'entity'
        target = agent.resolve_path(resolve_kind, path, location)
        # Fresh-process CWD: the PROJECT checkout root, so './workflow.rb'
        # resolves in the child even when the kind roots point at a sandbox
        # (tests/probes). Derived from the kind definition, never hardcoded.
        root_dir = agent.path_kind_definition(resolve_kind).fetch('project_root', nil) ||
                   File.expand_path('../../..', agent.path_kind_definition(resolve_kind).fetch('roots').fetch('project').to_s)
        name = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          raise ParameterException,
                "smoke: entity '#{path}' failed at stage=check: target does not exist or is not a file: #{target}"
        end

        content = File.read(target.to_s)
        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          raise ParameterException,
                "smoke: entity '#{path}' failed at stage=check: ruby syntax error: #{e.message}"
        end

        module_name = ScoutCoder.path_kind_entity_module_name(name)

        script = <<~RUBY
          require 'scout-ai'
          module_name = #{module_name.inspect}
          draft = #{target.to_s.inspect}
          stage = 'load'
          load draft
          mod = Object.const_get(module_name) rescue nil
          abort("smoke: failed at stage=define: entity module not defined after workflow load: \#{module_name}") if mod.nil?
          stage = 'register'
          unless Entity::MODULES.include?(mod)
            abort("smoke: failed at stage=register: entity module not registered in Entity::MODULES: \#{module_name}")
          end
          puts "SMOKE_OK stage=\#{stage} entity=\#{module_name} dispatched=false"
        RUBY

        out, err, status = Open3.capture3(RbConfig.ruby, '-e', script,
                                          chdir: root_dir)
        if status.success?
          {'ok' => true, 'kind' => 'entity', 'op' => 'smoke',
           'path' => path, 'location' => location, 'module' => module_name,
           'stage' => 'register', 'dispatched' => false,
           'exit_status' => status.exitstatus,
           'stdout' => out, 'stderr' => err}
        else
          detail = (out + err).lines.collect(&:strip).reject(&:empty?).last.to_s[0, 300]
          raise ParameterException,
                "smoke: entity '#{path}' (module #{module_name}) failed (exit #{status.exitstatus}): #{detail}"
        end
      end,

      'promotion_destination' => 'project'

      # (Round 10, step 6: the paired-test RELOCATION hook is REMOVED.
      # Test files are first-class `test_file` kind resources that promote
      # themselves through the test_file kind's own promote path; the Path
      # engine promotes one resource at a time and ScoutCoder coordinates
      # related promotions. A source-kind promotion therefore moves ONLY
      # the source file.)
  }.freeze
end
