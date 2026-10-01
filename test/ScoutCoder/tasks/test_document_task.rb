require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/, '\1')
require 'test/unit'

class DocumentTaskTest < Test::Unit::TestCase
  def test_appends_entry_at_end_of_tasks_section
    readme = "# Guide\n\n# Tasks\n\n## existing\n\nExisting docs.\n\n# Other\n\nOther section.\n"
    result = ScoutCoder::TaskReadme.replace_task_entry(readme, 'fresh_task', 'Fresh docs.')

    assert_match(/## fresh_task\n\nFresh docs\.\n\n# Other/, result)
    assert_equal 1, result.scan(/^## fresh_task$/).length
  end

  def test_replaces_existing_entry_without_changing_following_entries
    readme = "# Tasks\n\n## target\n\nOld docs.\n\n## later\n\nLater docs.\n"
    result = ScoutCoder::TaskReadme.replace_task_entry(readme, 'target', 'New docs.')

    assert_match(/## target\n\nNew docs\.\n\n## later/, result)
    assert_not_match(/Old docs/, result)
  end

  def test_requires_tasks_section
    assert_raise(ParameterException) do
      ScoutCoder::TaskReadme.replace_task_entry('# Intro\n', 'task', 'Docs')
    end
  end
end
