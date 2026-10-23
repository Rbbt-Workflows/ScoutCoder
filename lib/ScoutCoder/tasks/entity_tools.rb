require 'ripper'
require 'fileutils'

module ScoutCoder
  module EntityDefinitionSupport
    # Entity-TYPE names are CamelCase (canonical; decision artifact
    # reports/entity-case-convention-decision.md). Legacy snake_case
    # names (LEGACY_NAME) are accepted with a warning, never renamed.
    # Property names stay snake_case (PROPERTY_NAME) — properties are
    # methods, entity types are Ruby constants.
    NAME = /\A[A-Z][A-Za-z0-9]*\z/
    LEGACY_NAME = /\A[a-z][a-z0-9_]*\z/
    PROPERTY_NAME = /\A[a-z][a-z0-9_]*\z/
    BASES = { 'Entity' => 'Entity', 'EntityWorkflow' => 'EntityWorkflow' }.freeze

    module_function

    def project_root
      File.expand_path('../../..', __dir__)
    end

    # Canonical CamelCase names are accepted. Legacy snake_case names are
    # ACCEPTED with their spelling unchanged — never renamed, never
    # hard-rejected; pass a `warnings` array to collect the acceptance
    # warning (entity_name_warning) for surfacing. Hard errors are
    # reserved for constant collisions, which require the sibling drafts
    # and are therefore checked by the entity path-kind validator.
    def validate_name(name, label, warnings: nil)
      value = name.to_s
      case name_case(value)
      when :legacy
        warnings << entity_name_warning(value) if warnings
      when :invalid
        raise ArgumentError,
              "invalid #{label} #{value.inspect}; expected CamelCase [A-Z][A-Za-z0-9]* " \
              '(legacy snake_case [a-z][a-z0-9_]* is accepted with a warning)'
      end
      value
    end

    # :canonical (CamelCase), :legacy (snake_case, accepted with a
    # warning) or :invalid — the classification the entity and
    # entity_property path-kind validators branch on as well.
    def name_case(name)
      value = name.to_s
      return :canonical if NAME.match?(value)
      return :legacy if LEGACY_NAME.match?(value)
      :invalid
    end

    # The acceptance warning for a legacy snake_case entity name: names
    # BOTH the snake spelling and the CamelCase constant it maps to.
    # nil for canonical/invalid names.
    def entity_name_warning(name)
      return nil unless name_case(name) == :legacy
      "legacy snake_case entity name '#{name}' accepted with its spelling unchanged; " \
      "it maps to module constant '#{constant_name(name)}' (canonical spelling is CamelCase)"
    end

    # Shared entity-TYPE segment validation for the `entity` and
    # `entity_property` path-kind validators (decision artifact
    # reports/entity-case-convention-decision.md): CamelCase is canonical,
    # legacy snake_case is ACCEPTED with a warning (spelling unchanged, no
    # rename, no hard reject), anything else is an error. Returns the
    # expected module constant (constant_name), or nil when the name was
    # rejected. When `sibling_root` names a directory holding sibling
    # entity definition files, constant collisions become hard errors: a
    # legacy snake name camelising onto a CamelCase file's constant, and
    # two snake names camelising onto the same constant (Rule B collapses
    # underscore runs: a_b/a__b -> AB).
    def validate_entity_type_name!(name, sibling_root = nil, errors = [], warnings = [], label = 'entity name')
      value = name.to_s
      this_case = name_case(value)
      if this_case == :legacy
        warnings << entity_name_warning(value)
      elsif this_case != :canonical
        errors << "invalid #{label} #{value.inspect}: expected CamelCase [A-Z][A-Za-z0-9]* " \
                  '(legacy snake_case [a-z][a-z0-9_]* is accepted with a warning)'
        return nil
      end

      constant = constant_name(value)

      return constant unless sibling_root && File.directory?(sibling_root)

      Dir.glob(File.join(sibling_root, '*.rb')).sort.each do |other|
        other_name = File.basename(other, '.rb')
        next if other_name == value
        other_constant = constant_name(other_name)
        next unless other_constant == constant
        before = errors.length
        case [this_case, name_case(other_name)]
        when %i[legacy canonical]
          errors << "constant collision: legacy snake_case #{label} '#{value}' and CamelCase " \
                    "#{label} '#{other_name}' both map to module constant '#{constant}'"
        when %i[canonical legacy]
          errors << "constant collision: #{label} '#{value}' collides with legacy snake_case " \
                    "#{label} '#{other_name}' (both map to module constant '#{constant}')"
        when %i[legacy legacy]
          errors << "constant collision: legacy snake_case #{label}s '#{value}' and '#{other_name}' " \
                    "both camelise to module constant '#{constant}' " \
                    "(split('_').map(&:capitalize).join collapses underscore runs)"
        end
        # Keep scanning until a collision is actually recorded: a sibling
        # with a colliding constant but an UNCLASSIFIABLE name (invalid
        # case, e.g. 'Demo_Widget') is not one of the two decided
        # hard-error pairs and must not stop the scan early.
        break if errors.length > before
      end

      constant
    end

    # ScoutCoder: Misc.camel_case must NOT be used for the legacy
    # snake_case -> constant direction: it splits on digit runs as well as
    # underscores (scout-essentials misc/format.rb, `split(/_|(\d+)/)`)
    # and capitalizes the digit segments, so hex/digit-bearing names are
    # mangled and do not round-trip (workflow_entity_probe_12_727a8b ->
    # WorkflowEntityProbe12727A8B, matching only 1/18 declared draft
    # modules), and it collapses underscore boundaries (a_b and a__b both
    # -> AB). Rule B (split('_').map(&:capitalize).join) matches 18/18
    # legacy drafts, but still collapses a_b/a__b -> AB (why snake-name
    # constant collisions are a validation error) and MANGLES CamelCase
    # input (DemoWidget -> Demowidget, TF -> Tf), so canonical CamelCase
    # names must pass through UNCHANGED.
    def constant_name(name)
      return name.to_s if NAME.match?(name.to_s)
      name.to_s.split('_').map(&:capitalize).join
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

    # ScoutCoder: Misc.snake_case is the CamelCase -> snake direction
    # (keeps acronyms: TF -> TF, HTTPServer -> HTTP_server) but is LOSSY
    # for digit-bearing names (WorkflowEntityProbe12727a8b ->
    # workflow_entity_probe12727a8b: digit runs are not re-separated), so
    # it must never feed a path<->file map — it is only for generating a
    # snake spelling where one is genuinely needed.
    # ScoutCoder: Misc.snake_case is the CamelCase -> snake direction
    # (keeps acronyms: TF -> TF, HTTPServer -> HTTP_server) but is LOSSY
    # for digit-bearing names (WorkflowEntityProbe12727a8b ->
    # workflow_entity_probe12727a8b: digit runs are not re-separated), so
    # it must never feed a path<->file map — it is only for generating a
    # snake spelling where one is genuinely needed.
    def entity_name_from_constant(constant)
      Misc.snake_case(constant.to_s)
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
end
