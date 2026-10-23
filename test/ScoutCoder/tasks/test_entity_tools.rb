require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'fileutils'
require 'tmpdir'

class ListEntitiesTest < Test::Unit::TestCase
  SUPPORT = ScoutCoder::EntityDefinitionSupport

  def build_entity(name, base: Entity)
    constant = SUPPORT.constant_name(name)
    entity = Module.new
    Object.const_set(constant, entity)
    entity.extend(base)
    entity
  end

  def remove_entity(name)
    constant = SUPPORT.constant_name(name)
    Object.send(:remove_const, constant) if Object.const_defined?(constant, false)
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
    assert_equal 1, Entity::MODULES.count { |entry| entry.equal?(entity) }
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
    entity_path = File.join(root, 'share', 'entities', "#{name}.rb")
    property_path = File.join(root, 'share', 'entity_properties', name, 'sample.rb')
    FileUtils.mkdir_p(File.dirname(property_path))
    File.write(entity_path, "# source marker\n")
    File.write(property_path, "# property marker\n")
    entity = build_entity(name)
    entity.properties[:sample] = []
    step = ScoutCoder.job(:list_entities)
    step.clean
    record = step.run.find { |item| item[:name] == name }
    assert_not_nil record
    assert_equal "share/entities/#{name}.rb", record.dig(:source, :definition)
    assert_equal ["share/entity_properties/#{name}/sample.rb"], record.dig(:source, :property_files)
    assert_equal %i[annotations base_kind formats identifier_files module name properties source], record.keys.sort
  ensure
    remove_entity(name) if name
    File.delete(property_path) if property_path && File.file?(property_path)
    FileUtils.rmdir(File.dirname(property_path)) if property_path && File.directory?(File.dirname(property_path)) rescue nil
    File.delete(entity_path) if entity_path && File.file?(entity_path)
  end
end

# ---------------------------------------------------------------------------
# CamelCase entity-TYPE naming convention (decision artifact
# reports/entity-case-convention-decision.md, item 6): the converters and
# the name gate are pinned here at the unit level; the engine-facing
# validate matrix lives in test/ScoutCoder/test_path_kinds.rb.
# ---------------------------------------------------------------------------
class EntityTypeNameConventionTest < Test::Unit::TestCase
  SUPPORT = ScoutCoder::EntityDefinitionSupport

  # -- constant_name: canonical CamelCase passes through UNCHANGED

  def test_constant_name_passes_camelcase_through_unchanged
    assert_equal 'DemoWidget', SUPPORT.constant_name('DemoWidget')
    assert_equal 'TF', SUPPORT.constant_name('TF')
    assert_equal 'TF2', SUPPORT.constant_name('TF2')
    assert_equal 'HTTPServer', SUPPORT.constant_name('HTTPServer')
  end

  # -- constant_name: legacy snake camelises by Rule B

  def test_constant_name_camelizes_legacy_snake_by_rule_b
    assert_equal 'DemoWidget', SUPPORT.constant_name('demo_widget')
    assert_equal 'Gene', SUPPORT.constant_name('gene')
    assert_equal 'Trailing', SUPPORT.constant_name('trailing_')
    assert_equal 'X1A2b', SUPPORT.constant_name('x_1_a2b')
    # Rule B collapses underscore runs — the reason snake-name constant
    # collisions are a validation error, not a rename.
    assert_equal 'AB', SUPPORT.constant_name('a__b')
    assert_equal 'AB', SUPPORT.constant_name('a_b')
  end

  def test_constant_name_digit_bearing_legacy_name_uses_rule_b
    # THE digit-behavior assertion that justifies rejecting Misc.camel_case
    # for this direction (probed in the decision investigation):
    # Misc.camel_case splits on digit runs and capitalizes the digit
    # segments, so the hex-bearing draft names do not round-trip
    # (...12727A8B vs the declared ...12727a8b module). Rule B matches
    # all 18 legacy draft modules.
    name = 'workflow_entity_probe_12_727a8b'
    assert_equal 'WorkflowEntityProbe12727a8b', SUPPORT.constant_name(name)
    assert_equal 'WorkflowEntityProbe12727A8B', Misc.camel_case(name),
                 'documentation-of-rejection: this mangling is why ' \
                 'constant_name must NOT delegate to Misc.camel_case'
  end

  # -- name_case classification

  def test_name_case_classifies_canonical_legacy_invalid
    assert_equal :canonical, SUPPORT.name_case('TF')
    assert_equal :canonical, SUPPORT.name_case('TF2')
    assert_equal :canonical, SUPPORT.name_case('DemoWidget')
    assert_equal :canonical, SUPPORT.name_case('A')
    assert_equal :legacy, SUPPORT.name_case('demo_widget')
    assert_equal :legacy, SUPPORT.name_case('tf')
    assert_equal :legacy, SUPPORT.name_case('trailing_')
    assert_equal :invalid, SUPPORT.name_case('Demo_Widget')
    assert_equal :invalid, SUPPORT.name_case('_leading')
    assert_equal :invalid, SUPPORT.name_case('demoWidget')
    assert_equal :invalid, SUPPORT.name_case('')
  end

  # -- validate_name / entity_name_warning

  def test_validate_name_hard_rejects_underscore_camelcase
    e = assert_raise(ArgumentError) { SUPPORT.validate_name('Demo_Widget', 'entity name') }
    assert_match(/invalid entity name "Demo_Widget"; expected CamelCase \[A-Z\]\[A-Za-z0-9\]\*/, e.message)
    assert_match(/legacy snake_case .* accepted with a warning/, e.message)
  end

  def test_validate_name_accepts_canonical_silently
    warnings = []
    assert_equal 'DemoWidget', SUPPORT.validate_name('DemoWidget', 'entity name', warnings: warnings)
    assert_empty warnings
  end

  def test_validate_name_accepts_legacy_with_warning_naming_both_spellings
    warnings = []
    assert_equal 'demo_widget', SUPPORT.validate_name('demo_widget', 'entity name', warnings: warnings),
                 'legacy spelling must pass through UNCHANGED (no rename)'
    assert_equal 1, warnings.length
    assert_include warnings.first, "legacy snake_case entity name 'demo_widget'"
    assert_include warnings.first, "module constant 'DemoWidget'"
  end

  def test_entity_name_warning_is_nil_outside_the_legacy_branch
    assert_nil SUPPORT.entity_name_warning('DemoWidget')
    assert_nil SUPPORT.entity_name_warning('Demo_Widget')
    assert_match(/demo_widget.*DemoWidget/m, SUPPORT.entity_name_warning('demo_widget'))
  end

  # -- entity_name_from_constant: the CamelCase -> snake direction stays
  #    Misc.snake_case and is documented lossy for digit-bearing names;
  #    it is never fed to the path<->file map.

  def test_entity_name_from_constant_is_misc_snake_case_and_digit_lossy
    assert_equal 'demo_widget', SUPPORT.entity_name_from_constant('DemoWidget')
    assert_equal 'TF', SUPPORT.entity_name_from_constant('TF')
    # Lossy for digit-bearing names (documented): the constant
    # WorkflowEntityProbe12727a8b came from the draft file name, and the
    # path<->file map keeps the file spelling — this converter is only for
    # display/lookup defaults, not for deriving file names.
    assert_equal 'workflow_entity_probe12727a8b', SUPPORT.entity_name_from_constant('WorkflowEntityProbe12727a8b')
  end

  # -- validate_entity_type_name! collision matrix (sibling scan)

  def with_sibling_root(files)
    root = Dir.mktmpdir('sibling-entities')
    files.each do |name, content|
      File.write(File.join(root, "#{name}.rb"), content || "module #{SUPPORT.constant_name(name)}\n  extend Entity\nend\n")
    end
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_collision_snake_and_camelcase_is_hard_error_both_directions
    with_sibling_root('demo_widget' => nil, 'DemoWidget' => nil) do |root|
      errors, warnings = [], []
      constant = SUPPORT.validate_entity_type_name!('demo_widget', root, errors, warnings, 'entity name')
      assert_equal 'DemoWidget', constant
      assert_equal 1, warnings.length, 'legacy acceptance warning still surfaces beside the collision error'
      assert_equal 1, errors.length
      assert_match(/constant collision: legacy snake_case entity name 'demo_widget' and CamelCase entity name 'DemoWidget' both map to module constant 'DemoWidget'/, errors.first)

      errors, warnings = [], []
      constant = SUPPORT.validate_entity_type_name!('DemoWidget', root, errors, warnings, 'entity name')
      assert_equal 'DemoWidget', constant
      assert_empty warnings
      assert_equal 1, errors.length
      assert_match(/entity name 'DemoWidget' collides with legacy snake_case entity name 'demo_widget'/, errors.first)
    end
  end

  def test_collision_rule_b_collapse_between_two_snake_names_is_hard_error
    with_sibling_root('a_b' => nil, 'a__b' => nil) do |root|
      %w[a_b a__b].each do |name|
        errors, warnings = [], []
        constant = SUPPORT.validate_entity_type_name!(name, root, errors, warnings, 'entity name')
        assert_equal 'AB', constant
        assert_equal 1, errors.length, "#{name}: Rule-B collapse must be a hard error"
        assert_match(/both camelise to module constant 'AB' .*collapses underscore runs/, errors.first)
      end
    end
  end

  def test_no_collision_when_constants_differ_or_when_invalid_sibling_is_present
    # Distinct constants, no collision.
    with_sibling_root('demo_widget' => nil, 'other_widget' => nil, 'TF' => nil) do |root|
      errors, warnings = [], []
      assert_equal 'DemoWidget', SUPPORT.validate_entity_type_name!('demo_widget', root, errors, warnings, 'entity name')
      assert_empty errors
      assert_equal 1, warnings.length
    end

    # An INVALID sibling name (e.g. Demo_Widget beside DemoWidget) has a
    # colliding constant but is not one of the decided hard-error pairs;
    # the scan keeps going and records no error for it.
    with_sibling_root('DemoWidget' => nil, 'Demo_Widget' => "module X\n  extend Entity\nend\n") do |root|
      errors, warnings = [], []
      assert_equal 'DemoWidget', SUPPORT.validate_entity_type_name!('DemoWidget', root, errors, warnings, 'entity name')
      assert_empty errors, 'invalid-case sibling must not be reported as a collision here'
      assert_empty warnings
    end
  end

  def test_validate_entity_type_name_returns_nil_on_invalid_name
    errors, warnings = [], []
    assert_nil SUPPORT.validate_entity_type_name!('Demo_Widget', nil, errors, warnings, 'entity name')
    assert_equal 1, errors.length
    assert_match(/invalid entity name "Demo_Widget"/, errors.first)
    assert_empty warnings
  end
end

class EntityLoaderOrderTest < Test::Unit::TestCase
  def test_workflow_loader_orders_entities_before_properties_on_update
    name = "loader_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    constant = ScoutCoder::EntityDefinitionSupport.constant_name(name)
    entity_path = File.expand_path("../../../share/entities/#{name}.rb", __dir__)
    property_path = File.expand_path("../../../share/entity_properties/#{name}/loader_property.rb", __dir__)
    FileUtils.mkdir_p(File.dirname(property_path))
    File.write(entity_path, "module ::#{constant}; extend Entity; end\n")
    File.write(property_path, "module ::#{constant}; property(:loader_property) { 'ok' }; end\n")
    workflow = Workflow.require_workflow(File.expand_path('../../../workflow.rb', __dir__), update: true)
    entity = Object.const_get(constant, false)
    assert_include entity.properties.keys, :loader_property
    entity.properties.clear
    Workflow.require_workflow(File.expand_path('../../../workflow.rb', __dir__), update: true)
    entity = Object.const_get(constant, false)
    assert_include entity.properties.keys, :loader_property
  ensure
    File.delete(property_path) if property_path && File.file?(property_path)
    FileUtils.rmdir(File.dirname(property_path)) if property_path && File.directory?(File.dirname(property_path)) rescue nil
    File.delete(entity_path) if entity_path && File.file?(entity_path)
  end

  def test_reload_failure_restores_callers_working_directory
    original_directory = Dir.pwd
    root = File.expand_path('../../../tmp/workflows/failing_reload_probe', __dir__)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, 'workflow.rb'), "raise ArgumentError, 'simulated loader error'\n")
    error = assert_raise(ArgumentError) do
      ScoutCoder::EntityDefinitionSupport.reload!('candidate.rb', 'failure probe', root)
    end
    assert_match(/simulated loader error/, error.message)
    assert_equal original_directory, Dir.pwd
  ensure
    FileUtils.rm_rf(root) if root && File.directory?(root)
  end
end
