require 'ripper'
require 'fileutils'
require 'stringio'

module ScoutCoder
  module EntityDefinitionSupport
    NAME = /\A[a-z][a-z0-9_]*\z/
    BASES = { 'Entity' => 'Entity', 'EntityWorkflow' => 'EntityWorkflow' }.freeze

    module_function

    def project_root
      File.expand_path('../../..', __dir__)
    end

    def validate_name(name, label)
      value = name.to_s
      raise ArgumentError, "invalid #{label} #{value.inspect}; expected [a-z][a-z0-9_]*" unless NAME.match?(value)
      value
    end

    def constant_name(name)
      name.split('_').map(&:capitalize).join
    end

    def target_file(root, *parts)
      base = File.expand_path(File.join(root, 'share', 'entities'))
      target = File.expand_path(File.join(base, *parts))
      raise ArgumentError, "target path escapes share/entities directory: #{target}" unless target.start_with?(base + File::SEPARATOR)
      target
    end

    def property_file(root, entity_name, property_name)
      base = File.expand_path(File.join(root, 'share', 'entity_properties'))
      target = File.expand_path(File.join(base, entity_name, "#{property_name}.rb"))
      raise ArgumentError, "target path escapes share/entity_properties directory: #{target}" unless target.start_with?(base + File::SEPARATOR)
      target
    end

    def identifier_file(root, name)
      base = File.expand_path(File.join(root, 'share', 'entity'))
      target = File.expand_path(File.join(base, "#{name}.identifiers.tsv"))
      raise ArgumentError, "identifier path escapes share/entity directory: #{target}" unless target == base || target.start_with?(base + File::SEPARATOR)
      target
    end

    def no_existing_file!(path, label)
      raise ArgumentError, "#{label} already exists at #{path}; refusing to overwrite" if path && File.exist?(path)
    end

    def write_exclusive(path, content, label)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(content) }
    rescue Errno::EEXIST
      raise ArgumentError, "#{label} already exists at #{path}; refusing to overwrite"
    end

    def property_declaration?(source, property)
      lexed = Ripper.lex(source)
      lexed.each_with_index.any? do |(_position, type, text, _state), index|
        next false unless type == :on_ident && text == 'property'
        symbol_index = index + 1
        symbol_index += 1 while lexed[symbol_index]&.[](1) == :on_sp
        name_index = symbol_index + 1
        lexed[symbol_index]&.[](1) == :on_symbeg && lexed[symbol_index]&.[](2) == ':' &&
          lexed[name_index]&.[](1) == :on_ident && lexed[name_index]&.[](2) == property
      end
    end

    def entity_extension?(source)
      syntax = Ripper.sexp(source)
      return false unless syntax

      contains_entity_extension_call?(syntax)
    end

    def contains_entity_extension_call?(node)
      return false unless node.is_a?(Array)

      case node[0]
      when :method_add_arg
        return true if call_method_name(node[1]) == 'extend' &&
                       extension_arguments?(node[2])
      when :command
        return true if identifier_name(node[1]) == 'extend' &&
                       extension_arguments?(node[2])
      when :command_call
        return true if identifier_name(node[3]) == 'extend' &&
                       extension_arguments?(node[4])
      end

      node.any? { |child| contains_entity_extension_call?(child) }
    end

    def call_method_name(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :fcall, :vcall then identifier_name(node[1])
      when :call then identifier_name(node[3])
      when :method_add_arg, :method_add_block then call_method_name(node[1])
      end
    end

    def identifier_name(node)
      node[0] == :@ident ? node[1] : nil if node.is_a?(Array)
    end

    def extension_arguments?(arguments)
      arguments = arguments[1] if ast_node?(arguments, :arg_paren)
      arguments = arguments[1] if ast_node?(arguments, :args_add_block)
      argument_list_contains_entity?(arguments)
    end

    def argument_list_contains_entity?(arguments)
      return false if arguments.nil?

      if ast_node?(arguments, :args_add_star)
        previous, splat, trailing = arguments[1], arguments[2], arguments[3]
        return true if argument_list_contains_entity?(previous)
        return true if static_splat_contains_entity?(splat)
        return argument_list_contains_entity?(trailing)
      end

      items = ast_node?(arguments) ? [arguments] : arguments
      items.any? do |argument|
        entity_constant?(argument) ||
          (ast_node?(argument, :args_add_star) &&
           (argument_list_contains_entity?(argument[1]) || static_splat_contains_entity?(argument[2])))
      end
    end

    def static_splat_contains_entity?(expression)
      expression = expression[1] if ast_node?(expression, :paren)
      return false unless ast_node?(expression, :array)

      argument_list_contains_entity?(expression[1])
    end

    def entity_constant?(expression)
      return false unless expression.is_a?(Array)

      case expression[0]
      when :var_ref
        expression[1][0] == :@const && %w[Entity EntityWorkflow].include?(expression[1][1])
      when :top_const_ref
        expression[1][0] == :@const && %w[Entity EntityWorkflow].include?(expression[1][1])
      when :paren
        argument_list_contains_entity?(expression[1])
      else
        false
      end
    end

    def ast_node?(value, type = nil)
      value.is_a?(Array) && value[0].is_a?(Symbol) && (type.nil? || value[0] == type)
    end

    def tokens(source)
      # Ripper emits spaces and newlines as tokens; discard them so syntactic
      # neighbors such as `extend Entity` remain adjacent for declaration checks.
      Ripper.lex(source).reject do |_position, type, _text, _state|
        %i[on_sp on_ignored_nl on_nl on_comment].include?(type)
      end
    end

    def compile!(source, path, label)
      return if Ripper.sexp(source)
      raise ArgumentError, "invalid #{label} Ruby syntax at #{path}"
    end

    def entity_source(name, base, definition, identifiers: false)
      constant = constant_name(name)
      identifier_source = if identifiers
                            "  add_identifiers Path.setup(File.expand_path('../entity/#{name}.identifiers.tsv', __dir__))\n"
                          else
                            ''
                          end
      <<~RUBY
        module ::#{constant}
          extend #{base}
        #{identifier_source}#{definition.lines.map { |line| "  #{line}" }.join.rstrip}
        end
      RUBY
    end

    def property_source(entity_name, definition)
      <<~RUBY
        module ::#{constant_name(entity_name)}
        #{definition.lines.map { |line| "  #{line}" }.join.rstrip}
        end
      RUBY
    end

    def reload!(target, label, root = project_root)
      workflow_file = File.join(root, 'workflow.rb')
      begin
        root = File.expand_path(root)
        workflow = Workflow.workflows.find do |candidate|
          candidate.respond_to?(:libdir) && candidate.libdir &&
            File.expand_path(candidate.libdir.to_s) == root
        end
        unless workflow
          raise LoadError, "workflow entrypoint not found: #{workflow_file}" unless File.file?(workflow_file)
          require 'pathname'
          workflow = Dir.chdir(root) { Workflow.require_workflow_file(Pathname.new(workflow_file)) }
          workflow = Workflow.workflows.find do |candidate|
            candidate.respond_to?(:libdir) && candidate.libdir &&
              File.expand_path(candidate.libdir.to_s) == root
          end || workflow
        end
        workflow.load_live_files! if workflow.respond_to?(:load_live_files!)
        workflow
      rescue StandardError, ScriptError => error
        raise ArgumentError, "#{label} reload failed after writing candidate #{target}; workflow entrypoint #{workflow_file} raised #{error.class}: #{error.message}"
      end
    end

    def workflow_root(workflow)
      raise ArgumentError, "workflow '#{workflow}' has no checkout libdir" if workflow.nil? || workflow.libdir.nil? || workflow.libdir.to_s.empty?
      File.expand_path(workflow.libdir.to_s)
    end

    def scoutcoder_entity(name, root = project_root)
      constant = constant_name(name)
      if Object.const_defined?(constant, false)
        entity = Object.const_get(constant, false)
        unless defined?(Entity) && Entity === entity && entity.respond_to?(:properties)
          raise ArgumentError, "entity registration failed: ::#{constant} is not an Entity"
        end
        return entity
      end

      constant = constant_name(name)
      candidate = File.join(root, 'share', 'entities', "#{name}.rb")
      if File.file?(candidate)
        load candidate
      end
      raise ArgumentError, "entity registration failed: ::#{constant} is not defined" unless Object.const_defined?(constant, false)
      entity = Object.const_get(constant, false)
      raise ArgumentError, "entity registration failed: ::#{constant} is not an Entity" unless defined?(Entity) && Entity === entity && entity.respond_to?(:properties)
      entity
    end

    def entity_modules(scope = nil)
      return [] unless defined?(Entity)
      scoped_entities = scope.constants(false).sort_by(&:to_s).filter_map do |constant|
        next if scope.autoload?(constant)
        entity = scope.const_get(constant, false)
        entity if entity.is_a?(Module) && Entity === entity && entity.respond_to?(:properties)
      end if scope
      return scoped_entities if scope
      # Entity::MODULES is append-only: re-loading a checkout entity file
      # re-extends and re-appends the same module object, so deduplicate.
      Entity::MODULES.uniq
    end

    def entity_name_from_constant(constant)
      constant.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2').gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase
    end

    def json_metadata(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = json_metadata(item) }
      when Array then value.map { |item| json_metadata(item) }
      when Symbol then value.to_s
      when String, Integer, Float, TrueClass, FalseClass, NilClass then value
      when Module then value.name || value.to_s
      else value.respond_to?(:to_path) ? value.to_path : value.to_s
      end
    end

    def method_available?(entity, method_name)
      entity.respond_to?(method_name, true)
    end

    def effective_dispatch(entity, property)
      return 'single' if method_available?(entity, "_single_#{property}")
      return 'array' if method_available?(entity, "_ary_#{property}")
      return 'multiple' if method_available?(entity, "_multi_#{property}")
      'both'
    end

    def checkout_path(path, root)
      return nil if path.nil?
      value = path.respond_to?(:to_path) ? path.to_path : path.to_s
      expanded = File.expand_path(value, root)
      expanded.start_with?(root + File::SEPARATOR) ? expanded.delete_prefix(root + File::SEPARATOR) : value
    end

    def entity_source_metadata(entity, root)
      constant = entity.name.to_s.split('::').last
      entity_dir = File.join(root, 'share', 'entities')
      definition_files = File.directory?(entity_dir) ? Dir.glob(File.join(entity_dir, '*.rb')).sort.select { |path| constant_name(File.basename(path, '.rb')) == constant } : []
      name = definition_files.empty? ? entity_name_from_constant(constant) : File.basename(definition_files.first, '.rb')
      property_dir = File.join(root, 'share', 'entity_properties', name)
      property_files = File.directory?(property_dir) ? Dir.glob(File.join(property_dir, '**', '*.rb')).sort : []
      { name: name, definition: definition_files.empty? ? nil : checkout_path(definition_files.first, root),
        property_files: property_files.map { |path| checkout_path(path, root) } }
    end

    def entity_inspection(entity, root)
      source = entity_source_metadata(entity, root)
      properties = (entity.properties || {}).keys.map(&:to_s).sort.map do |property|
        { name: property, effective_dispatch: effective_dispatch(entity, property),
          persisted: !!(entity.respond_to?(:persisted?) && entity.persisted?(property.to_sym)) }
      end
      workflow_base = defined?(Workflow) && entity.singleton_class.ancestors.include?(Workflow)
      annotations = entity.respond_to?(:annotations) ? json_metadata(entity.annotations || {}) : {}
      formats = entity.respond_to?(:formats) ? json_metadata(entity.formats) : nil
      identifier_files = entity.respond_to?(:identifier_files) ? Array(entity.identifier_files).map { |path| checkout_path(path, root) } : nil
      { name: source[:name], module: entity.name, base_kind: workflow_base ? 'EntityWorkflow' : 'Entity',
        source: { definition: source[:definition], property_files: source[:property_files] },
        annotations: annotations, formats: formats, identifier_files: identifier_files, properties: properties }
    end
  end

  input :entity_name, :string, 'Entity identifier (lowercase letters, digits and underscores; starts with a letter)', nil, required: true
  input :definition, :text, 'Trusted Ruby source for the entity body (annotations, helpers, and other declarations; do not include the module or extend line)', nil, required: true
  input :base, :string, 'Entity base: Entity (default) or EntityWorkflow', 'Entity'
  input :identifiers, :text, 'Optional TSV file contents; written to share/entity/<entity>.identifiers.tsv and registered at load time', nil
  input :workflow, :string, 'Workflow whose share/entities directory receives the entity', 'ScoutCoder'
  task :define_entity => :json do |entity_name, definition, base, identifiers, workflow|
    begin
      name = EntityDefinitionSupport.validate_name(entity_name, 'entity name')
      raise ArgumentError, 'definition must be non-empty Ruby source' unless definition.is_a?(String) && !definition.strip.empty?
      selected_base = EntityDefinitionSupport::BASES[base.to_s]
      raise ArgumentError, "base must be one of #{EntityDefinitionSupport::BASES.keys.join(', ')}" unless selected_base
      raise ArgumentError, 'definition body must not extend Entity or EntityWorkflow; select the base with the base input' if EntityDefinitionSupport.entity_extension?(definition)
      target_workflow = managed_workflow(workflow)
      root = EntityDefinitionSupport.workflow_root(target_workflow)
      workflow_name = target_workflow.to_s
      constant = EntityDefinitionSupport.constant_name(name)
      if Object.const_defined?(constant, false)
        existing = Object.const_get(constant, false)
        unless defined?(Entity) && Entity === existing && existing.respond_to?(:properties)
          raise ArgumentError, "constant ::#{constant} is already defined and is not an Entity; refusing to redefine it"
        end
        # Existing top-level entities are augmented by adding share/entity_properties files.
      end
      entity_path = EntityDefinitionSupport.target_file(root, "#{name}.rb")
      identifiers_path = identifiers.nil? ? nil : EntityDefinitionSupport.identifier_file(root, name)
      raise ArgumentError, 'identifiers must be non-empty TSV text when supplied' if identifiers_path && (!identifiers.is_a?(String) || identifiers.empty?)
      EntityDefinitionSupport.no_existing_file!(entity_path, 'entity definition')
      EntityDefinitionSupport.no_existing_file!(identifiers_path, 'identifier TSV') if identifiers_path
      source = EntityDefinitionSupport.entity_source(name, selected_base, definition, identifiers: !identifiers_path.nil?)
      EntityDefinitionSupport.compile!(source, entity_path, 'entity definition')
      if identifiers_path
        begin
          TSV.parse_header(StringIO.new(identifiers))
        rescue StandardError => error
          raise ArgumentError, "invalid identifier TSV header: #{error.message}"
        end
        EntityDefinitionSupport.write_exclusive(identifiers_path, identifiers, 'identifier TSV')
      end
      begin
        EntityDefinitionSupport.write_exclusive(entity_path, source, 'entity definition')
      rescue StandardError
        File.delete(identifiers_path) if identifiers_path && File.file?(identifiers_path)
        raise
      end
      EntityDefinitionSupport.reload!(entity_path, 'define_entity', root)
      entity = EntityDefinitionSupport.scoutcoder_entity(name, root)
      unless Object.const_defined?(constant, false) && Object.const_get(constant, false).equal?(entity)
        raise ArgumentError, "entity registration failed: ::#{constant} is not defined at top level"
      end
      { entity: name, constant: "::#{constant}", workflow: workflow_name, base: selected_base, path: entity_path, identifiers_path: identifiers_path,
        bytes: source.bytesize, validation: { entity_name: 'passed', source: 'passed', base: 'passed', syntax: 'passed', load: 'passed', registration: 'passed' },
        written: true, overwritten: false }
    rescue ArgumentError => error
      raise ParameterException, "define_entity validation/authoring failed: #{error.message}"
    end
  end
  export_exec :define_entity

  input :entity_name, :string, 'Existing ScoutCoder entity identifier', nil, required: true
  input :property_name, :string, 'Property identifier (lowercase letters, digits and underscores; starts with a letter)', nil, required: true
  input :definition, :text, 'Trusted Ruby source containing property :<property_name> declaration', nil, required: true
  input :workflow, :string, 'Workflow whose share/entity_properties directory receives the property', 'ScoutCoder'
  task :define_entity_property => :json do |entity_name, property_name, definition, workflow|
    begin
      name = EntityDefinitionSupport.validate_name(entity_name, 'entity name')
      property = EntityDefinitionSupport.validate_name(property_name, 'property name')
      raise ArgumentError, 'definition must be non-empty Ruby source' unless definition.is_a?(String) && !definition.strip.empty?
      raise ArgumentError, "definition must contain a property :#{property} declaration (not only a comment or string)" unless EntityDefinitionSupport.property_declaration?(definition, property)
      target_workflow = managed_workflow(workflow)
      root = EntityDefinitionSupport.workflow_root(target_workflow)
      constant = EntityDefinitionSupport.constant_name(name)
      unless Object.const_defined?(constant, false)
        target_workflow = managed_workflow(workflow)
        EntityDefinitionSupport.reload!(File.join(EntityDefinitionSupport.workflow_root(target_workflow), 'workflow.rb'), 'define_entity_property', EntityDefinitionSupport.workflow_root(target_workflow))
      end
      raise ArgumentError, "entity ::#{constant} is not defined; define or load it before adding a property" unless Object.const_defined?(constant, false)
      # Properties are attached to the top-level Entity module, while their
      # source file belongs to the selected workflow's share tree. The entity
      # may have been originally defined by a different checkout.
      entity = EntityDefinitionSupport.scoutcoder_entity(name, root)
      raise ArgumentError, "property :#{property} is already registered on ::#{EntityDefinitionSupport.constant_name(name)}; refusing to redefine it" if (entity.properties || {}).keys.map(&:to_s).include?(property)
      property_path = EntityDefinitionSupport.property_file(root, name, property)
      EntityDefinitionSupport.no_existing_file!(property_path, 'entity property definition')
      source = EntityDefinitionSupport.property_source(name, definition)
      EntityDefinitionSupport.compile!(source, property_path, 'entity property')
      EntityDefinitionSupport.write_exclusive(property_path, source, 'entity property definition')
      EntityDefinitionSupport.reload!(property_path, 'define_entity_property', root)
      entity = EntityDefinitionSupport.scoutcoder_entity(name, root)
      raise ArgumentError, "property registration failed: ::#{EntityDefinitionSupport.constant_name(name)}.properties does not include :#{property}" unless (entity.properties || {}).keys.map(&:to_s).include?(property)
      unless Object.const_defined?(constant, false) && Object.const_get(constant, false).equal?(entity)
        raise ArgumentError, "property registration failed: ::#{constant} is not defined at top level"
      end
      { entity: name, property: property, workflow: target_workflow.to_s, path: property_path, bytes: source.bytesize,
        validation: { entity_name: 'passed', property_name: 'passed', source: 'passed', declaration: 'passed', syntax: 'passed', load: 'passed', registration: 'passed' },
        written: true, overwritten: false }
    rescue ArgumentError => error
      raise ParameterException, "define_entity_property validation/authoring failed: #{error.message}"
    end
  end
  export_exec :define_entity_property

end
