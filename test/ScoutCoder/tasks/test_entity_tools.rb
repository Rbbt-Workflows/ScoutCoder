require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'fileutils'
require 'tmpdir'

class EntityToolsTest < Test::Unit::TestCase
  def test_entity_and_property_authoring_with_identifiers_and_reload_order
    name = "entity_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    property = "token_#{SecureRandom.hex(3)}"
    constant = ScoutCoder::EntityDefinitionSupport.constant_name(name)
    entity_path = File.expand_path("../../../lib/ScoutCoder/entity/#{name}.rb", __dir__)
    property_path = File.expand_path("../../../lib/ScoutCoder/entity/#{name}/#{property}.rb", __dir__)
    identifiers_path = File.expand_path("../../../share/entity/#{name}.identifiers.tsv", __dir__)
    entity_definition = "annotation :organism, 'Organism'\n"
    property_definition = "property :#{property} do\n  \"#{self}\"\nend"
    script = <<~'RUBY'
      require './workflow'
      require 'json'
      name, property, entity_definition, property_definition = ARGV
      entity = ScoutCoder.job(:define_entity, nil, entity_name: name,
                              definition: entity_definition, base: 'Entity',
                              identifiers: "#ID,Name\nid1,one\n").run
      raise 'entity registration missing' unless ScoutCoder.const_defined?(ScoutCoder::EntityDefinitionSupport.constant_name(name), false)
      property_result = ScoutCoder.job(:define_entity_property, nil,
                                       entity_name: name, property_name: property,
                                       definition: property_definition).run
      entity_module = ScoutCoder.const_get(ScoutCoder::EntityDefinitionSupport.constant_name(name), false)
      raise 'property missing after reload' unless entity_module.properties.keys.map(&:to_s).include?(property)
      raise 'identifier file was not registered' unless entity_module.identifier_files.any? { |path| path.to_s.end_with?("#{name}.identifiers.tsv") }
      raise 'identifier path is not absolute' unless entity_module.identifier_files.first.to_s.start_with?('/')
      puts JSON.generate(entity: entity, property: property_result,
                         property_names: entity_module.properties.keys.map(&:to_s))
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script,
                                             name, property, entity_definition, property_definition,
                                             chdir: File.expand_path('../../..', __dir__))
    assert_predicate status, :success?, "isolated entity authoring failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
    result = JSON.parse(stdout)
    assert_equal 'passed', result.dig('entity', 'validation', 'registration')
    assert_equal 'passed', result.dig('property', 'validation', 'registration')
    assert_include result.fetch('property_names'), property
    assert File.file?(identifiers_path)
  ensure
    File.delete(property_path) if property_path && File.file?(property_path)
    FileUtils.rmdir(File.dirname(property_path)) if property_path && File.directory?(File.dirname(property_path)) rescue nil
    File.delete(entity_path) if entity_path && File.file?(entity_path)
    File.delete(identifiers_path) if identifiers_path && File.file?(identifiers_path)
  end

  def test_entity_authoring_reloads_checkout_lib_when_process_cwd_is_elsewhere
    name = "external_cwd_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    root = File.expand_path('../../../', __dir__)
    entity_path = File.join(root, 'lib', 'ScoutCoder', 'entity', "#{name}.rb")
    identifiers_path = File.join(root, 'share', 'entity', "#{name}.identifiers.tsv")
    script = <<~'RUBY'
      require 'json'
      require 'tmpdir'
      root, name = ARGV
      Dir.chdir(Dir.tmpdir)
      require File.join(root, 'workflow')
      result = ScoutCoder.job(:define_entity, nil, entity_name: name,
                              definition: "annotation :organism, 'Organism'\n",
                              identifiers: "#ID,Name\nid1,one\n").run
      entity = ScoutCoder.const_get(ScoutCoder::EntityDefinitionSupport.constant_name(name), false)
      expected = File.join(root, 'share', 'entity', "#{name}.identifiers.tsv")
      actual = entity.identifier_files.map(&:to_s)
      raise "identifier path mismatch: #{actual.inspect}" unless actual.include?(expected)
      puts JSON.generate(result: result, identifiers: actual)
    RUBY
    Dir.mktmpdir('scoutcoder-external-cwd-') do |outside_root|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby,
                                               "-I#{File.join(root, 'lib')}", '-e', script,
                                               root, name, chdir: outside_root)
      assert_predicate status, :success?, "external-cwd entity authoring failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
      result = JSON.parse(stdout)
      assert_equal entity_path, result.dig('result', 'path')
      assert_equal identifiers_path, result.dig('result', 'identifiers_path')
      assert_equal [identifiers_path], result.fetch('identifiers')
      assert_equal 'passed', result.dig('result', 'validation', 'registration')
    end
  ensure
    File.delete(entity_path) if entity_path && File.file?(entity_path)
    File.delete(identifiers_path) if identifiers_path && File.file?(identifiers_path)
  end

  def test_entity_workflow_base_is_opt_in_and_not_double_extended
    name = "workflow_entity_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    entity_path = File.expand_path("../../../lib/ScoutCoder/entity/#{name}.rb", __dir__)
    script = <<~'RUBY'
      require './workflow'
      name = ARGV.fetch(0)
      result = ScoutCoder.job(:define_entity, nil, entity_name: name,
                              definition: "property :from_workflow do; 'ok'; end",
                              base: 'EntityWorkflow').run
      entity = ScoutCoder.const_get(ScoutCoder::EntityDefinitionSupport.constant_name(name), false)
      raise 'EntityWorkflow base not applied' unless entity.respond_to?(:tasks)
      raise 'property metadata was reset' unless entity.properties.key?(:from_workflow)
      puts result[:base]
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script, name,
                                             chdir: File.expand_path('../../..', __dir__))
    assert_predicate status, :success?, "EntityWorkflow authoring failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
    assert_include stdout, 'EntityWorkflow'
  ensure
    File.delete(entity_path) if entity_path && File.file?(entity_path)
  end

  def test_validation_rejects_invalid_or_overwrite_attempts
    assert_raise(ParameterException) do
      ScoutCoder.job(:define_entity, nil, entity_name: '../escape', definition: 'true').run
    end
    name = "overwrite_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    path = File.expand_path("../../../lib/ScoutCoder/entity/#{name}.rb", __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '# existing')
    assert_raise(ParameterException) do
      ScoutCoder.job(:define_entity, nil, entity_name: name, definition: 'true').run
    end
    assert_equal '# existing', File.read(path)
    File.delete(path)
    assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend Entity\n")
    assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend EntityWorkflow\n")
    assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend(\n  Entity\n)")
    assert_equal false, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend\n  Entity\n")
    assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend(Entity)")
    assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend(EntityWorkflow)")
    assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend ( EntityWorkflow )")
    assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?("extend Entity\nannotation :note, 'text'")
    [
      'extend(::Entity)',
      'extend(Entity,)',
      'extend(Entity, Module.new)',
      'extend(*[Entity])',
      'extend(*[Other, ::Entity])',
      'extend(Other, *[Entity])',
      'extend(EntityWorkflow, Module.new)',
      'self.extend(::Entity)'
    ].each do |source|
      assert_equal true, ScoutCoder::EntityDefinitionSupport.entity_extension?(source), source
    end
    [
      'extend(OtherEntity)',
      'extend(Entity::Other)',
      'extend(Other::Entity)',
      'extend(name)',
      'extend(*modules)',
      'obj.other(Entity)',
      "# extend Entity\nannotation :note, 'extend Entity'\n",
      'annotation :note, "extend(::Entity)"'
    ].each do |source|
      assert_equal false, ScoutCoder::EntityDefinitionSupport.entity_extension?(source), source
    end
    assert_raise(ParameterException) do
      ScoutCoder.job(:define_entity_property, nil, entity_name: 'not_registered_here',
                     property_name: 'bad', definition: 'property :other do; end').run
    end
  end
end

class ListEntitiesTest < Test::Unit::TestCase
  SUPPORT = ScoutCoder::EntityDefinitionSupport

  def build_entity(name, base: Entity)
    constant = SUPPORT.constant_name(name)
    entity = Module.new
    ScoutCoder.const_set(constant, entity)
    entity.extend(base)
    entity
  end

  def remove_entity(name)
    constant = SUPPORT.constant_name(name)
    ScoutCoder.send(:remove_const, constant) if ScoutCoder.const_defined?(constant, false)
  end

  def test_empty_scope_contains_no_entities
    assert_equal [], SUPPORT.entity_modules(Module.new)
  end

  def test_no_scope_returns_all_known_entity_modules
    name = "registry_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    entity = build_entity(name)
    modules = SUPPORT.entity_modules
    assert_include modules, entity
    assert_equal Entity::MODULES.uniq, modules
  ensure
    remove_entity(name) if name
  end

  def test_no_scope_deduplicates_registry_entries_for_reloaded_entities
    name = "dup_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    entity = build_entity(name)
    entity.extend(Entity) # mimics a checkout entity file being re-loaded
    assert_equal 2, Entity::MODULES.count { |entry| entry.equal?(entity) }
    assert_equal 1, SUPPORT.entity_modules.count { |entry| entry.equal?(entity) }
  ensure
    remove_entity(name) if name
  end

  def test_scope_returns_only_entity_modules_under_scope
    name = "scope_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    scope = Module.new
    entity = build_entity(name)
    scope.const_set(:ScopedEntity, entity)
    scope.const_set(:PlainModule, Module.new)
    scope.const_set(:PlainClass, Class.new)
    scope.const_set(:NotAModule, 'plain string')
    scope.autoload(:LazyEntity, 'nonexistent/lazy_entity')
    assert_equal [entity], SUPPORT.entity_modules(scope)
  ensure
    remove_entity(name) if name
  end

  def test_entity_dispatch_and_persistence_metadata
    suffix = "#{Process.pid}_#{SecureRandom.hex(3)}"
    name = "listing_probe_#{suffix}"
    entity = build_entity(name)
    properties = %w[single_prop single_alias array_prop array_alias multiple_prop plain_prop persisted_prop]
    entity.instance_variable_set(:@properties, properties.each_with_object({}) { |item, hash| hash[item.to_sym] = [] })
    %w[single_prop single_alias].each { |item| entity.define_singleton_method("_single_#{item}") {} }
    %w[array_prop array_alias].each { |item| entity.define_singleton_method("_ary_#{item}") {} }
    entity.define_singleton_method(:_multi_multiple_prop) {}
    entity.define_singleton_method(:persisted?) { |item| item.to_sym == :persisted_prop }
    record = SUPPORT.entity_inspection(entity, SUPPORT.project_root)
    dispatch = record[:properties].to_h { |item| [item[:name], item[:effective_dispatch]] }
    assert_equal 'single', dispatch['single_prop']
    assert_equal 'single', dispatch['single_alias']
    assert_equal 'array', dispatch['array_prop']
    assert_equal 'array', dispatch['array_alias']
    assert_equal 'multiple', dispatch['multiple_prop']
    assert_equal 'both', dispatch['plain_prop']
    assert_equal true, record[:properties].find { |item| item[:name] == 'persisted_prop' }[:persisted]
    assert_equal false, record[:properties].find { |item| item[:name] == 'plain_prop' }[:persisted]
    assert_equal 'Entity', record[:base_kind]
    assert_kind_of Array, record[:annotations]
    assert record.key?(:formats)
  ensure
    remove_entity(name) if name
  end

  def test_entityworkflow_base_is_reported
    name = "listing_workflow_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    entity = build_entity(name, base: EntityWorkflow)
    assert_equal 'EntityWorkflow', SUPPORT.entity_inspection(entity, SUPPORT.project_root)[:base_kind]
  ensure
    remove_entity(name) if name
  end

  def test_task_reports_loaded_entities_and_lib_source_paths
    suffix = "#{Process.pid}_#{SecureRandom.hex(3)}"
    name = "listing_source_probe_#{suffix}"
    root = SUPPORT.project_root
    entity_path = File.join(root, 'lib', 'ScoutCoder', 'entity', "#{name}.rb")
    property_path = File.join(root, 'lib', 'ScoutCoder', 'entity', name, 'sample.rb')
    FileUtils.mkdir_p(File.dirname(property_path))
    File.write(entity_path, "# source marker\n")
    File.write(property_path, "# property marker\n")
    entity = build_entity(name)
    entity.properties[:sample] = []
    step = ScoutCoder.job(:list_entities)
    step.clean
    record = step.run.find { |item| item[:name] == name }
    assert_not_nil record
    assert_equal "lib/ScoutCoder/entity/#{name}.rb", record.dig(:source, :definition)
    assert_equal ["lib/ScoutCoder/entity/#{name}/sample.rb"], record.dig(:source, :property_files)
    assert_equal %i[annotations base_kind formats identifier_files module name properties source], record.keys.sort
  ensure
    remove_entity(name) if name
    File.delete(property_path) if property_path && File.file?(property_path)
    FileUtils.rmdir(File.dirname(property_path)) if property_path && File.directory?(File.dirname(property_path)) rescue nil
    File.delete(entity_path) if entity_path && File.file?(entity_path)
  end
end

class EntityLoaderOrderTest < Test::Unit::TestCase
  def test_workflow_loader_orders_entities_before_properties_on_update
    name = "loader_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    constant = ScoutCoder::EntityDefinitionSupport.constant_name(name)
    entity_path = File.expand_path("../../../lib/ScoutCoder/entity/#{name}.rb", __dir__)
    property_path = File.expand_path("../../../lib/ScoutCoder/entity/#{name}/loader_property.rb", __dir__)
    FileUtils.mkdir_p(File.dirname(property_path))
    File.write(entity_path, "module ScoutCoder; module #{constant}; extend Entity; end; end\n")
    File.write(property_path, "module ScoutCoder; module #{constant}; property(:loader_property) { 'ok' }; end; end\n")
    workflow = Workflow.require_workflow(File.expand_path('../../../workflow.rb', __dir__), update: true)
    entity = workflow.const_get(constant, false)
    assert_include entity.properties.keys, :loader_property
    entity.properties.clear
    Workflow.require_workflow(File.expand_path('../../../workflow.rb', __dir__), update: true)
    entity = ScoutCoder.const_get(constant, false)
    assert_include entity.properties.keys, :loader_property
  ensure
    File.delete(property_path) if property_path && File.file?(property_path)
    FileUtils.rmdir(File.dirname(property_path)) if property_path && File.directory?(File.dirname(property_path)) rescue nil
    File.delete(entity_path) if entity_path && File.file?(entity_path)
  end

  def test_reload_failure_restores_callers_working_directory
    original_directory = Dir.pwd
    original_loader = Workflow.method(:require_workflow)
    Workflow.define_singleton_method(:require_workflow) { |*| raise ArgumentError, 'simulated loader error' }
    error = assert_raise(ArgumentError) do
      ScoutCoder::EntityDefinitionSupport.reload!('candidate.rb', 'failure probe')
    end
    assert_match(/simulated loader error/, error.message)
    assert_equal original_directory, Dir.pwd
  ensure
    Workflow.define_singleton_method(:require_workflow, original_loader) if original_loader
  end
end
