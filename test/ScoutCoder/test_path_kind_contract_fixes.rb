require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'fileutils'
require 'json'
require 'tmpdir'

# ---------------------------------------------------------------------------
# Round: path-kind contract fixes 2 / 4 / 6 (in-checkout description and
# validation-surface changes; NO tier-mapping spelling changes).
#
#   fix 4 — `module ::Gene` must VALIDATE for the `entity` kind (and the
#           property module-match for `entity_property`): the session
#           evidence (main.chat#44-48) showed the old detector rejecting a
#           legal Ruby top-level spelling with a misleading "found none".
#           The detector now accepts an optional leading "::" while
#           capturing the bare name
#           (path_kinds/test_file.rb path_kind_top_level_modules).
#   fix 2 — every path-tool-facing kind description carries one compact
#           virtual-path GRAMMAR statement (relative to the kind root, no
#           .rb suffix, no physical prefix; nested for entity_property;
#           "." root selector only for enumeration on test_file).
#   fix 6 — the test_file kind description surfaces the tier PAIRING MAP
#           (tmp -> project spellings for task / entity / entity_property /
#           integration, including the tmp-side entity_property asymmetry
#           <entity>/<entity>.<property>.rb, NOT <entity>/<property>.rb).
#
# These tests are grep-style description assertions on distinctive
# substrings (robust to minor rewording) plus behavior checks through the
# validate path. Description assertions run against the PATH_KINDS
# constants AS LOADED for this process (the same objects the engine copies
# at registration), and against the registered agent surface after
# integrate_workflow_path_kinds for the test_file pairing map.
# ---------------------------------------------------------------------------
class TestPathKindContractFixes < Test::Unit::TestCase
  def setup
    @sandbox = Dir.mktmpdir('r-fix246')
    @saved_cwd = Dir.pwd
    @agent = LLM::Agent.new
    @agent.integrate_workflow_path_kinds(ScoutCoder)
  end

  def teardown
    Dir.chdir(@saved_cwd) if @saved_cwd && Dir.pwd != @saved_cwd
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # ---------------------------------------------------------------- helpers

  # The entity / entity_property validate lambdas hardcode their kind name
  # (agent.resolve_path('entity', ...)), so the sandbox copy must be
  # registered under the REAL name for the handler to resolve into the
  # sandbox roots. This agent is per-test (created in setup) and the
  # PATH_KINDS constant itself is not mutated — only this agent's registry
  # entry is repointed, so no cross-test leakage.
  def sandbox_kind!(kind)
    base = @agent.path_kind_definition(kind)
    copy = {}
    base.each { |k, v| copy[k] = v }
    copy['roots'] = {
      'tmp' => Path.setup(File.join(@sandbox, 'share', KIND_SUBDIR[kind])),
      'project' => Path.setup(File.join(@sandbox, 'lib', 'ScoutCoder'))
    }
    @agent.register_path_kind(kind, copy)
    kind
  end

  KIND_SUBDIR = {
    'entity' => 'entities', 'entity_property' => 'entity_properties',
    'task' => 'tasks', 'test_file' => 'test'
  }.freeze

  def write_draft(kind, path, content)
    root = @agent.path_kind_definition(kind)['roots']['tmp']
    full = File.join(root, "#{path}.rb")
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  def kind_root(kind)
    @agent.path_kind_definition(kind)['roots']['tmp'].to_s
  end

  # Drive the engine's validate the same way the regression suite does:
  # through the installed tool (path_validate), which routes through the
  # agent's operation table and the sandboxed-kind root pins.
  def validate_result(kind, path)
    h = { 'kind' => kind, 'path' => path, 'location' => 'tmp' }
    @agent.other_options[:tools]['path_validate'].first.call('path_validate', h)
  end

  def entity_fixture!(kind, entity, property: nil, module_prefix: '')
    content =
      if property
        "module #{module_prefix}#{ScoutCoder.path_kind_entity_module_name(entity)}\n" \
          "  property :#{property} => :single do\n    'x'\n  end\nend\n"
      else
        "module #{module_prefix}#{ScoutCoder.path_kind_entity_module_name(entity)}\n" \
          "  extend Entity\nend\n"
      end
    virtual = property ? "#{entity}/#{property}" : entity
    write_draft(kind, virtual, content)
  end


  # ------------------------------------------------------------ fix 4 tests

  def test_entity_validate_accepts_module_colon_colon_spelling
    Dir.chdir(@sandbox)
    sandbox_kind!('entity')
    write_draft('entity', 'gene', "module ::Gene\n  extend Entity\nend\n")
    r = validate_result('entity', 'gene')
    assert_equal true, r['ok'], "module ::Gene must validate: #{r['reasons'].inspect}"
    assert_equal 'Gene', r['module'], 'bare name must be captured despite the leading ::'

    write_draft('entity', 'demo_widget', "module DemoWidget\n  extend Entity\nend\n")
    r = validate_result('entity', 'demo_widget')
    assert_equal true, r['ok'], "module Gene spelling must still validate: #{r['reasons'].inspect}"
  end

  def test_entity_property_validate_module_match_accepts_leading_colons
    Dir.chdir(@sandbox)
    sandbox_kind!('entity')
    sandbox_kind!('entity_property')
    write_draft('entity', 'gene', "module ::Gene\n  extend Entity\nend\n")
    write_draft('entity_property', 'gene/entrez', "module ::Gene\n  property :entrez => :single do\n    'x'\n  end\nend\n")
    r = validate_result('entity_property', 'gene/entrez')
    assert_equal true, r['ok'], "property file under module ::Gene must validate: #{r['reasons'].inspect}"
    assert_equal 'Gene', r['module']
  end

  def test_entity_validate_still_rejects_mismatched_module_name
    Dir.chdir(@sandbox)
    sandbox_kind!('entity')
    write_draft('entity', 'other_thing', "module ::Gene\n  extend Entity\nend\n")
    r = validate_result('entity', 'other_thing')
    assert_equal false, r['ok']
    assert_match(/top-level module must be `OtherThing`/, r['reasons'].join(' '))
  end

  def test_top_level_modules_helper_captures_bare_name_for_both_spellings
    mods = ScoutCoder.path_kind_top_level_modules(
      "module ::Gene\nend\nmodule Foo\nend\nmodule ::Bar::Baz\nend\nmodule Nested::Mod\nend\n"
    )
    assert_equal %w[Gene Foo], mods,
                 'leading :: accepted; nested/qualified names are NOT top-level declarations'
  end

  # ------------------------------------------------------------ fix 2 tests

  def test_all_kind_descriptions_carry_the_grammar_sentence
    ScoutCoder::PATH_KINDS.each do |name, defn|
      desc = defn['description'].to_s
      assert_include desc, 'Virtual paths are relative to the kind root',
                     "#{name} description must state the grammar anchor"
      assert_include desc, '.rb suffix',
                     "#{name} description must warn against the .rb suffix"
    end
  end

  def test_entity_property_description_states_nested_shape
    assert_include ScoutCoder::PATH_KINDS['entity_property']['description'],
                   'NESTED'
    assert_include ScoutCoder::PATH_KINDS['entity_property']['description'],
                   '<entity>/<property>'
  end

  def test_run_test_task_desc_carries_grammar
    desc = ScoutCoder.tasks[:run_test].description.to_s
    assert_include desc, 'tier-prefixed'
    assert_include desc, 'no .rb suffix'
    assert_include desc, 'project checkout that owns the test file'
  end

  def test_run_test_custom_op_description_carries_grammar_and_anchor
    d = ScoutCoder.path_kind_test_file_definition['operations']['run_test']['description'].to_s
    assert_include d, 'relative to the test_file kind root'
    assert_include d, 'no .rb suffix'
    assert_include d, 'owns the test file'
  end

  # ------------------------------------------------------------ fix 6 tests

  def test_test_file_description_carries_the_pairing_map
    d = ScoutCoder::PATH_KINDS['test_file']['description'].to_s
    assert_include d, 'Paired-test tiers'
    assert_include d, 'share/test/task/<name>.rb'
    assert_include d, 'test/ScoutCoder/tasks/test_<name>.rb'
    assert_include d, 'share/test/entity/<name>.rb'
    assert_include d, 'test/ScoutCoder/entity/test_<name>.rb'
    assert_include d, 'share/test/entity_property/<entity>/<entity>.<property>.rb'
    assert_include d, 'test/ScoutCoder/entity/<entity>/test_<property>.rb'
    assert_include d, 'share/test/integration/<name>.rb'
    assert_include d, 'test/ScoutCoder/integration/test_<name>.rb'
    # The tmp-side asymmetry is called out explicitly.
    assert_include d, 'NOT <entity>/<property>.rb'
  end

  def test_pairing_map_sentences_match_the_mapping_authority_spellings
    # The description echoes the SAME spellings path_kind_map_forward
    # produces; pin the distinctive ones so the echo cannot drift away
    # from the authority without failing here.
    d = ScoutCoder::PATH_KINDS['test_file']['description'].to_s
    fwd = ScoutCoder.path_kind_map_forward_segments(['task', 'greet_user'], 'tmp')
    assert_equal 'task/greet_user.rb', fwd, 'authority check (tmp task tier)'
    assert_include d, 'task -> share/test/task/<name>.rb -> test/ScoutCoder/tasks/test_<name>.rb'
    fwd = ScoutCoder.path_kind_map_forward_segments(['entity_property', 'demo_widget', 'tag_palette'], 'tmp')
    assert_equal 'entity_property/demo_widget/demo_widget.tag_palette.rb', fwd,
                 'authority check (tmp entity_property tier uses the doubled filename)'
  end
end
