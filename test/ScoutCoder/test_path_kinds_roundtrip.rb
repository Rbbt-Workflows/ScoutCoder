require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'fileutils'
require 'securerandom'
require 'tmpdir'

# ---------------------------------------------------------------------------
# Round-10 step 7: FIRST-CLASS round-trip regression suite for the
# `test_file` path kind — the acceptance backbone that makes "one reliable
# virtual-path interface" a TESTED property.
#
# Self-contained (re-declares the fixture manifests; does not import the
# step probes). Exercises the live ScoutCoder::PathKindTestFiles authority
# through its public surface:
#
#   path_kind_test_file_grammar        (lexical/structural gate)
#   path_kind_resolve_test_file        (virtual -> physical, containment)
#   path_kind_list_test_files          (prefix-honoring listing)
#   path_kind_virtual_path_for         (physical -> virtual inverse shim)
#   path_kind_map_forward_segments / path_kind_map_back (mapping authority)
#
# Every test builds a synthetic test tree in a tmp sandbox for BOTH
# locations, registers NOTHING on the engine, and calls the module
# functions directly under a CWD confined to the sandbox (the Scout
# `:current` map anchors the dynamic root lookup). The production
# definition, the engine and the real checkout trees are never touched.
#
# Properties, one test method each (granular failures):
#   P1 round-trip identity          test_round_trip_identity_*
#   P2 list<->resolve agreement     test_list_resolve_agreement_*
#   P3 injectivity                  test_injectivity_*
#   P4 rejection matrix             test_rejection_matrix_*
#   P5 containment + canaries       test_containment_*
#   P6 location partition           test_location_partition_*
# ---------------------------------------------------------------------------

class TestPathKindsRoundtrip < Test::Unit::TestCase
  TMP_LOCATION = 'tmp'.freeze
  PROJECT_LOCATION = 'project'.freeze
  LOCATIONS = [TMP_LOCATION, PROJECT_LOCATION].freeze

  # The fixture manifest: virtual file-shaped paths per tier. Name classes:
  # plain, underscore-bearing, dotted, mixed.
  VIRTUAL_FIXTURES = [
    'task/plain',
    'task/demo_widget',
    'task/my_task_name',
    'task/nested/deep',
    'task/nested/feature_dir_with_underscores/name.x',
    'entity/demo_widget',
    'entity/plain',
    'helper/helper_tools',
    'helper/my_helper',
    'entity_property/demo_widget/tag_palette',
    'entity_property/e/p',
    'entity_property/demo_widget/widget',
    'integration/rt',
    'integration/feature_dir_with_underscores/rt2',
    'sometier/open_one'
  ].freeze

  PHYSICAL_TMP = {
    'task/plain' => 'task/plain.rb',
    'task/demo_widget' => 'task/demo_widget.rb',
    'task/my_task_name' => 'task/my_task_name.rb',
    'task/nested/deep' => 'task/nested/deep.rb',
    'task/nested/feature_dir_with_underscores/name.x' =>
      'task/nested/feature_dir_with_underscores/name.x.rb',
    'entity/demo_widget' => 'entity/demo_widget.rb',
    'entity/plain' => 'entity/plain.rb',
    'helper/helper_tools' => 'helper/helper_tools.rb',
    'helper/my_helper' => 'helper/my_helper.rb',
    'entity_property/demo_widget/tag_palette' =>
      'entity_property/demo_widget/demo_widget.tag_palette.rb',
    'entity_property/e/p' => 'entity_property/e/e.p.rb',
    'entity_property/demo_widget/widget' =>
      'entity_property/demo_widget/demo_widget.widget.rb',
    'integration/rt' => 'integration/rt.rb',
    'integration/feature_dir_with_underscores/rt2' =>
      'integration/feature_dir_with_underscores/rt2.rb',
    'sometier/open_one' => 'sometier/open_one.rb'
  }.freeze

  PHYSICAL_PROJECT = {
    'task/plain' => 'tasks/test_plain.rb',
    'task/demo_widget' => 'tasks/test_demo_widget.rb',
    'task/my_task_name' => 'tasks/test_my_task_name.rb',
    'task/nested/deep' => 'tasks/nested/test_deep.rb',
    'task/nested/feature_dir_with_underscores/name.x' =>
      'tasks/nested/feature_dir_with_underscores/test_name.x.rb',
    'entity/demo_widget' => 'entity/test_demo_widget.rb',
    'entity/plain' => 'entity/test_plain.rb',
    'helper/helper_tools' => 'helper/test_helper_tools.rb',
    'helper/my_helper' => 'helper/test_my_helper.rb',
    'entity_property/demo_widget/tag_palette' =>
      'entity/demo_widget/test_tag_palette.rb',
    'entity_property/e/p' => 'entity/e/test_p.rb',
    'entity_property/demo_widget/widget' =>
      'entity/demo_widget/test_widget.rb',
    'integration/rt' => 'integration/test_rt.rb',
    'integration/feature_dir_with_underscores/rt2' =>
      'integration/feature_dir_with_underscores/test_rt2.rb',
    'sometier/open_one' => 'sometier/test_open_one.rb'
  }.freeze

  MALFORMED_INPUTS = [
    'task/../outside.rb',
    '../escape',
    '..',
    'a/../../b',
    '/etc/passwd',
    '/absolute/inside/root',
    'task//x',
    'task/trailing/',
    'task/.',
    "task/ctrl\x01x",
    'task/back\\slash',
    '~/home',
    "task/nul\x00",
    'entity_property/a/b/extra',
    'entity/a/b',
    'helper/a/b',
    'integration/a/b/c/d'
  ].freeze

  # ------------------------------------------------------------------ setup

  def setup
    @sandbox = Dir.mktmpdir('r10-roundtrip')
    @saved_cwd = Dir.pwd
    Dir.chdir(@sandbox)
    @tmp_root = File.join(@sandbox, 'share', 'test')
    @project_root = File.join(@sandbox, 'test', 'ScoutCoder')
    seed_fixture!
  end

  def teardown
    Dir.chdir(@saved_cwd) if @saved_cwd && Dir.pwd != @saved_cwd
    FileUtils.rm_rf(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  def seed_fixture!
    PHYSICAL_TMP.each_value do |rel|
      path = File.join(@tmp_root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# fixture #{rel}\n")
    end
    PHYSICAL_PROJECT.each_value do |rel|
      path = File.join(@project_root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# fixture #{rel}\n")
    end
  end

  def root_for(location)
    location == TMP_LOCATION ? @tmp_root : @project_root
  end

  def physical_for(virtual, location)
    (location == TMP_LOCATION ? PHYSICAL_TMP : PHYSICAL_PROJECT)[virtual]
  end

  # ------------------------------------------------- P1 round-trip identity

  def test_round_trip_identity_both_locations
    failures = []
    LOCATIONS.each do |location|
      VIRTUAL_FIXTURES.each do |virtual|
        resolved = ScoutCoder.path_kind_resolve_test_file(virtual, location).to_s
        expected = File.join(root_for(location), physical_for(virtual, location))
        failures << "#{location}:#{virtual} resolved #{resolved.inspect} != #{expected.inspect}" unless resolved == expected

        back = ScoutCoder.path_kind_virtual_path_for(
          physical_for(virtual, location), location
        )
        failures << "#{location}:#{virtual} inverse(physical) #{back.inspect} != #{virtual.inspect}" unless back == virtual
      end
    end
    assert failures.empty?, "round-trip failures:\n#{failures.join("\n")}"
  end

  def test_round_trip_identity_mapping_authority
    tf = ScoutCoder::PathKindTestFiles
    failures = []
    LOCATIONS.each do |location|
      VIRTUAL_FIXTURES.each do |virtual|
        segments = virtual.split('/')
        physical_rel = tf.path_kind_map_forward_segments(segments, location)
        back_segments = tf.path_kind_map_back(physical_rel, location)
        failures << "#{location}:#{virtual} map-back #{back_segments.inspect} != #{virtual}" unless back_segments == virtual
      end
    end
    assert failures.empty?, "mapping-authority failures:\n#{failures.join("\n")}"
  end

  # --------------------------------------------- P2 list<->resolve agreement

  def test_list_resolve_agreement_tier_prefixes_exact_sets
    expected_by_tier = {}
    VIRTUAL_FIXTURES.each do |virtual|
      tier = virtual.split('/').first
      expected_by_tier[tier] ||= []
      expected_by_tier[tier] << virtual
    end

    failures = []
    LOCATIONS.each do |location|
      expected_by_tier.each do |tier, expected|
        listed = ScoutCoder.path_kind_list_test_files(tier, location)
        unless listed == expected.sort
          failures << "#{location}:#{tier} listed #{listed.inspect} != #{expected.sort.inspect}"
        end
      end
    end
    assert failures.empty?, "tier-prefix listings:\n#{failures.join("\n")}"
  end

  def test_list_resolve_agreement_root_union_and_nested_prefixes
    failures = []
    LOCATIONS.each do |location|
      all = ScoutCoder.path_kind_list_test_files('.', location)
      union = VIRTUAL_FIXTURES.sort
      failures << "#{location}: root listing #{all.inspect} != #{union.inspect}" unless all == union

      nested = ScoutCoder.path_kind_list_test_files('task/nested', location)
      expected = %w[task/nested/deep task/nested/feature_dir_with_underscores/name.x].sort
      failures << "#{location}: nested #{nested.inspect} != #{expected.inspect}" unless nested == expected

      ep_entity = ScoutCoder.path_kind_list_test_files('entity_property/demo_widget', location)
      expected_ep = %w[entity_property/demo_widget/tag_palette entity_property/demo_widget/widget].sort
      failures << "#{location}: ep prefix #{ep_entity.inspect} != #{expected_ep.inspect}" unless ep_entity == expected_ep
    end
    assert failures.empty?, "root/nested prefixes:\n#{failures.join("\n")}"
  end

  def test_list_resolve_agreement_every_entry_resolves
    failures = []
    LOCATIONS.each do |location|
      ScoutCoder.path_kind_list_test_files('.', location).each do |listed|
        resolved = ScoutCoder.path_kind_resolve_test_file(listed, location).to_s
        unless File.file?(resolved)
          failures << "#{location}:#{listed} resolves to non-file #{resolved.inspect}"
        end
        physical_rel = File.expand_path(resolved).sub(%r{\A#{Regexp.escape(root_for(location))}/}, '')
        back = ScoutCoder.path_kind_virtual_path_for(physical_rel, location)
        failures << "#{location}:#{listed} inverse(resolve) #{back.inspect} != #{listed.inspect}" unless back == listed
      end
    end
    assert failures.empty?, "entry-resolution failures:\n#{failures.join("\n")}"
  end

  def test_list_resolve_agreement_determinism_and_file_shapes
    failures = []
    LOCATIONS.each do |location|
      a = ScoutCoder.path_kind_list_test_files('.', location)
      b = ScoutCoder.path_kind_list_test_files('.', location)
      failures << "#{location}: root listing not deterministic" unless a == b

      present = ScoutCoder.path_kind_list_test_files('task/plain', location)
      failures << "#{location}: file-shape present #{present.inspect}" unless present == ['task/plain']
      missing = ScoutCoder.path_kind_list_test_files('entity/absent_name', location)
      failures << "#{location}: missing file-shape #{missing.inspect}" unless missing == []
      missing_prefix = ScoutCoder.path_kind_list_test_files('task/no_such_dir', location)
      failures << "#{location}: missing prefix #{missing_prefix.inspect}" unless missing_prefix == []
    end
    assert failures.empty?, "determinism/file-shape failures:\n#{failures.join("\n")}"
  end

  # ---------------------------------------------------------- P3 injectivity

  def test_injectivity_pairwise_distinct_physical_targets
    failures = []
    LOCATIONS.each do |location|
      seen = {}
      VIRTUAL_FIXTURES.each do |virtual|
        resolved = ScoutCoder.path_kind_resolve_test_file(virtual, location).to_s
        if seen.key?(resolved)
          failures << "#{location}: #{virtual} and #{seen[resolved]} both -> #{resolved}"
        else
          seen[resolved] = virtual
        end
      end
    end
    assert failures.empty?, "injectivity failures:\n#{failures.join("\n")}"
  end

  # ------------------------------------------------------- P4 rejection matrix

  FS_RECORDER = Module.new do
    define_method(:exist?) { |*a, &b| @fs_calls << :exist? if @fs_recording; super(*a, &b) }
    define_method(:directory?) { |*a, &b| @fs_calls << :directory? if @fs_recording; super(*a, &b) }
    define_method(:file?) { |*a, &b| @fs_calls << :file? if @fs_recording; super(*a, &b) }
  end

  def test_rejection_matrix_resolve_and_list_before_fs_inspection
    @fs_calls = []
    @fs_recording = false
    File.singleton_class.prepend(FS_RECORDER) unless File.singleton_class < FS_RECORDER

    failures = []
    LOCATIONS.each do |location|
      MALFORMED_INPUTS.each do |bad|
        @fs_calls = []
        @fs_recording = true
        begin
          raised = nil
          begin
            ScoutCoder.path_kind_resolve_test_file(bad, location)
          rescue ParameterException => e
            raised = e
          end
          unless raised
            failures << "#{location}:#{bad.inspect} resolve did not raise ParameterException"
          end
          unless @fs_calls.empty?
            failures << "#{location}:#{bad.inspect} resolve touched FS first: #{@fs_calls.inspect}"
          end

          @fs_calls = []
          raised = nil
          begin
            ScoutCoder.path_kind_list_test_files(bad, location)
          rescue ParameterException => e
            raised = e
          end
          unless raised
            failures << "#{location}:#{bad.inspect} list did not raise ParameterException"
          end
          unless @fs_calls.empty?
            failures << "#{location}:#{bad.inspect} list touched FS first: #{@fs_calls.inspect}"
          end
        ensure
          @fs_recording = false
        end
      end
    end
    assert failures.empty?, "rejection-matrix failures:\n#{failures.join("\n")}"
  end

  # ------------------------------------------------- P5 containment + canaries

  def test_containment_rejects_outside_symlink_and_keeps_canary_intact
    canary = File.join(@sandbox, 'outside_canary.txt')
    File.write(canary, "canary bytes #{SecureRandom.hex(8)}\n")
    canary_bytes = File.read(canary)

    outside_dir = File.join(@sandbox, 'outside')
    FileUtils.mkdir_p(outside_dir)
    secret = File.join(outside_dir, 'secret.rb')
    File.write(secret, "# outside secret\n")

    # An outside-pointing symlink in EACH location's tree (tmp: task/escape.rb,
    # project: tasks/test_escape.rb — the mapped spellings of task/escape).
    tmp_link = File.join(@tmp_root, 'task', 'escape.rb')
    FileUtils.mkdir_p(File.dirname(tmp_link))
    File.symlink(secret, tmp_link)
    proj_link = File.join(@project_root, 'tasks', 'test_escape.rb')
    FileUtils.mkdir_p(File.dirname(proj_link))
    File.symlink(secret, proj_link)

    LOCATIONS.each do |location|
      raised = nil
      begin
        ScoutCoder.path_kind_resolve_test_file('task/escape', location)
      rescue ParameterException
        raised = true
      end
      assert raised, "#{location}: outside symlink resolve must raise ParameterException"
    end

    assert_equal canary_bytes, File.read(canary), 'outside canary altered'
    assert_equal "# outside secret\n", File.read(secret), 'outside secret altered'
  ensure
    File.delete(canary) if File.exist?(canary)
  end

  def test_containment_allows_inside_root_symlink_no_false_positive
    real = File.join(@tmp_root, 'task', 'real_file.rb')
    FileUtils.mkdir_p(File.dirname(real))
    File.write(real, "# real\n")
    link = File.join(@tmp_root, 'task', 'linked_file.rb')
    File.symlink(real, link)

    resolved = nil
    assert_nothing_raised do
      resolved = ScoutCoder.path_kind_resolve_test_file('task/linked_file', TMP_LOCATION)
    end
    assert File.file?(resolved.to_s), 'inside symlink should resolve to a file'
    back = ScoutCoder.path_kind_virtual_path_for(
      resolved.to_s.sub(%r{\A#{Regexp.escape(@tmp_root)}/}, ''), TMP_LOCATION)
    assert_equal 'task/linked_file', back
  end

  # --------------------------------------------------- P6 location partition

  def test_location_partition_no_cross_location_leakage
    failures = []
    LOCATIONS.each do |location|
      other = location == TMP_LOCATION ? PROJECT_LOCATION : TMP_LOCATION
      listed = ScoutCoder.path_kind_list_test_files('.', location)
      other_listed = ScoutCoder.path_kind_list_test_files('.', other)
      listed.each do |virtual|
        resolved = ScoutCoder.path_kind_resolve_test_file(virtual, location).to_s
        unless resolved.start_with?(root_for(location) + '/')
          failures << "#{location}:#{virtual} resolved outside its root: #{resolved}"
        end
        if resolved.start_with?(root_for(other) + '/')
          failures << "#{location}:#{virtual} leaked into #{other} tree: #{resolved}"
        end
      end
      assert_equal VIRTUAL_FIXTURES.sort, other_listed, "#{other} listing changed"
    end
    assert failures.empty?, "partition failures:\n#{failures.join("\n")}"
  end
end
