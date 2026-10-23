# The `entity_property` path kind (split out of path_kinds.rb in round 9).
# Behavior preserved from the pre-split definition; the aggregator
# lib/ScoutCoder/path_kinds.rb merges this constant into PATH_KINDS.
# See the aggregator header for the engine contract and load order
# (support + test_file load before any kind file).
module ScoutCoder

    # -------------------------------------------------------------------
    # Round 7: `entity_property` — entity property files with NESTED
    # virtual paths <entity>/<property>.rb (one kind, decision 2).
    #   tmp     -> <checkout>/share/entity_properties/<entity>/<property>.rb
    #   project -> <checkout>/lib/<workflow>/entity/<entity>/<property>.rb
    # Shape: top-level `module <CamelCase(entity segment)>` with at least one
    # `property :name => :type do ... end` and NO extend line (the entity file
    # owns the extend) — entity_tools.rb property_source.
    # Entity names are CamelCase (canonical; e.g. DemoWidget/palette);
    # legacy snake_case entity segments (demo_widget/tag_palette) are
    # accepted with a warning.
    # -------------------------------------------------------------------
  PATH_KIND_ENTITY_PROPERTY_DEFINITION = {
      'description' =>
        "Scout entity property files for #{target_workflow_name}, nested virtual paths " \
        '<entity>/<property>.rb (drafts in share/entity_properties, promoted ' \
        "copies in lib/#{target_workflow_name}/entity/<entity>/<property>.rb). " \
        'Virtual paths are relative to the kind root and NESTED: <entity>/<property> ' \
        'such as DemoWidget/palette (the entity segment is CamelCase, canonical; a ' \
        'legacy snake_case segment such as demo_widget/tag_palette is accepted with a ' \
        'warning), no .rb suffix and no physical prefix.',

      'extension' => 'rb',
      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      'roots' => {
        'tmp' => Scout.share.entity_properties,
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
        resolve_kind = args['kind'] || 'entity_property'
        target = agent.resolve_path(resolve_kind, path, location)
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
          # Decision artifact reports/entity-case-convention-decision.md:
          # the entity segment follows the same naming rules as the entity
          # kind — CamelCase canonical, legacy snake_case accepted with a
          # warning (no rename), module compared via constant_name.
          # Collision candidates are derived from the KIND ROOT, not from
          # the property file's own directory: on the tmp side the entity
          # drafts live in the SIBLING share/entities/ directory
          # (root share/entity_properties -> sibling share/entities), while
          # the project side shares the entity root itself
          # (lib/<workflow>/entity holds both <Entity>.rb and
          # <Entity>/<prop>.rb). First existing wins.
          kind_root = agent.path_kind_definition(resolve_kind)
                         .fetch('roots').fetch(location.to_s, nil)
          kind_root = agent.path_kind_definition(resolve_kind)
                         .fetch('roots').fetch('tmp', nil) if kind_root.nil?
          sibling_entities_root = [
            File.join(File.dirname(kind_root.to_s), 'entities'),
            kind_root.to_s
          ].find { |candidate| File.directory?(candidate) }
          expected = ScoutCoder::EntityDefinitionSupport.validate_entity_type_name!(
            entity, sibling_entities_root, errors, warnings, 'entity name'
          )
          declared = ScoutCoder.path_kind_top_level_module(content)
          if expected && declared != expected
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

      # -----------------------------------------------------------------
      # smoke (round 9 contract): the property is registered on the entity
      # module AND a real dispatch on a synthetic entity does not raise.
      # -----------------------------------------------------------------
      'smoke' => lambda do |agent, path, location, args|
        resolve_kind = args['kind'] || 'entity_property'
        target = agent.resolve_path(resolve_kind, path, location)
        # Fresh-process CWD: the PROJECT checkout root, so './workflow.rb'
        # resolves in the child even when the kind roots point at a sandbox
        # (tests/probes). Derived from the kind definition, never hardcoded.
        root_dir = agent.path_kind_definition(resolve_kind).fetch('project_root', nil) ||
                   File.expand_path('../../..', agent.path_kind_definition(resolve_kind).fetch('roots').fetch('project').to_s)
        entity = path.to_s.split(File::SEPARATOR).first.to_s
        property = File.basename(path.to_s, '.rb')

        unless File.file?(target.to_s)
          raise ParameterException,
                "smoke: entity_property '#{path}' failed at stage=check: target does not exist or is not a file: #{target}"
        end

        content = File.read(target.to_s)
        begin
          RubyVM::AbstractSyntaxTree.parse(content)
        rescue SyntaxError => e
          raise ParameterException,
                "smoke: entity_property '#{path}' failed at stage=check: ruby syntax error: #{e.message}"
        end

        module_name = ScoutCoder.path_kind_entity_module_name(entity)

        # Entity BEFORE property (loader contract): when the entity draft
        # sits in the sibling `entities/` root (share/) we load it first.
        # The promoted `lib/<workflow>/entity/` tree keeps the SAME layout
        # (entity files flat, property files nested) for the project side.
        # tmp roots: <root>/entity_properties/<entity>/<prop>.rb with the
        # entity draft at the SIBLING <root>/entities/<entity>.rb (share/
        # layout); one dirname strips <prop>.rb, the second strips
        # entity_properties/.
        entity_tmp = File.join(File.dirname(File.dirname(File.dirname(target.to_s))), 'entities', "#{entity}.rb")
        entity_prj = File.join(root_dir, 'lib', target_workflow_name.to_s, 'entity', "#{entity}.rb")
        script = <<~RUBY
          require 'scout-ai'
          module_name = #{module_name.inspect}
          property = #{property.inspect}
          entity_tmp = #{entity_tmp.inspect}
          entity_prj = #{entity_prj.inspect}
          draft = #{target.to_s.inspect}
          stage = 'load'
          entity_draft = [entity_tmp, entity_prj].find { |f| f && File.file?(f) }
          load entity_draft if entity_draft
          load draft
          mod = Object.const_get(module_name) rescue nil
          abort("smoke: failed at stage=define: entity module not defined after workflow load: \#{module_name}") if mod.nil?
          stage = 'register'
          unless mod.properties.keys.map(&:to_s).include?(property.to_s)
            abort("smoke: failed at stage=register: property not registered on \#{module_name}: \#{property} (has \#{mod.properties.keys.map(&:to_s).inspect})")
          end
          stage = 'resolve'
          method = mod.instance_method(property.to_sym) rescue nil
          if method.nil?
            abort("smoke: failed at stage=resolve: accessor :\#{property} does not resolve on \#{module_name} (instance_method returned nil)")
          end
          puts "SMOKE_OK stage=\#{stage} entity=\#{module_name} property=\#{property} dispatched=false"
        RUBY

        out, err, status = Open3.capture3(RbConfig.ruby, '-e', script,
                                          chdir: root_dir)
        if status.success?
          {'ok' => true, 'kind' => 'entity_property', 'op' => 'smoke',
           'path' => path, 'location' => location,
           'entity' => entity, 'property' => property, 'module' => module_name,
           'stage' => 'resolve', 'dispatched' => false,
           'exit_status' => status.exitstatus,
           'stdout' => out, 'stderr' => err}
        else
          detail = (out + err).lines.collect(&:strip).reject(&:empty?)
          msg = detail.grep(/smoke: failed at stage=/).last || detail.last || ''
          raise ParameterException,
                "smoke: entity_property '#{path}' (#{module_name}.#{property}) failed (exit #{status.exitstatus}): #{msg[0, 300]}"
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
