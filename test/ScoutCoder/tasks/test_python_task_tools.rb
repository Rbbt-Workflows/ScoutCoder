require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/, '\\1')
require 'test/unit'
require 'securerandom'
require 'tmpdir'

class PythonTaskToolsTest < Test::Unit::TestCase
  def test_define_python_task_writes_and_registers_complete_python_source
    name = "python_authoring_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    root = ScoutCoder::PythonTaskSupport.project_root
    task_path = File.join(root, 'python', 'tasks', "#{name}.py")
    source = <<~PYTHON
      import scout

      def #{name}(value: str) -> str:
          """Return a prefixed value.

          Args:
              value: The value to prefix.
          """
          return f"python:{value}"

      scout.task(#{name})
    PYTHON

    result = ScoutCoder.job(:define_python_task, nil,
      task_name: name, python_source: source, workflow: 'ScoutCoder'
    ).run
    assert_equal true, result[:written]
    assert_equal task_path, result[:path]
    assert_equal [name], result[:registered_tasks]
    assert_equal 'passed', result.dig(:validation, :metadata)
    assert_includes ScoutCoder.tasks, name.to_sym

    duplicate = ScoutCoder.job(:define_python_task, nil,
      task_name: name, python_source: source, workflow: 'ScoutCoder'
    )
    duplicate.clean if duplicate.done?
    assert_raise(ParameterException) { duplicate.run }
  ensure
    File.delete(task_path) if task_path && File.file?(task_path)
  end

  def test_define_python_task_supplies_only_missing_scout_import
    name = "python_authoring_no_import_#{Process.pid}_#{SecureRandom.hex(3)}"
    root = ScoutCoder::PythonTaskSupport.project_root
    task_path = File.join(root, 'python', 'tasks', "#{name}.py")
    source = <<~PYTHON
      def #{name}(value: str) -> str:
          """Return a prefixed value."""
          return f"python:{value}"

      scout.task(#{name})
    PYTHON

    result = ScoutCoder.job(:define_python_task, nil,
      task_name: name, python_source: source, workflow: 'ScoutCoder'
    ).run
    saved_source = File.read(task_path)
    assert_equal true, result[:framework_import_added]
    assert_match(/\Aimport scout\n/, saved_source)
    assert_includes saved_source, "def #{name}(value: str)"
    assert_includes saved_source, "scout.task(#{name})"
    assert_equal [name], result[:registered_tasks]
  ensure
    File.delete(task_path) if task_path && File.file?(task_path)
  end

  def test_define_python_task_preserves_future_import_and_existing_scout_import
    with_future = %Q{\"\"\"module docs\"\"\"\nfrom __future__ import annotations\ndef example() -> str:\n    return 'ok'\nscout.task(example)\n}
    transformed = ScoutCoder::PythonTaskSupport.with_scout_import(with_future)
    assert_equal %Q{\"\"\"module docs\"\"\"\nfrom __future__ import annotations\nimport scout\n}, transformed.lines.first(3).join

    existing = "import scout\ndef example():\n    return 'ok'\nscout.task(example)\n"
    assert_same existing, ScoutCoder::PythonTaskSupport.with_scout_import(existing)

    aliased_existing = "import scout as scout\ndef example():\n    return 'ok'\nscout.task(example)\n"
    assert_same aliased_existing, ScoutCoder::PythonTaskSupport.with_scout_import(aliased_existing)
  end

  def test_author_python_task_test_requires_task_and_writes_valid_python_without_overwrite
    name = "python_test_authoring_probe_#{Process.pid}_#{SecureRandom.hex(3)}"

    root = ScoutCoder::PythonTaskSupport.project_root
    task_path = File.join(root, 'python', 'tasks', "#{name}.py")
    test_path = File.join(root, 'python', 'test', "test_#{name}.py")
    File.write(task_path, "import scout\ndef #{name}() -> str:\n    return 'ok'\nscout.task(#{name})\n")
    source = "import unittest\n\nclass GeneratedTest(unittest.TestCase):\n    def test_ok(self):\n        self.assertEqual('ok', 'ok')\n"

    result = ScoutCoder.job(:author_python_task_test, nil,
      task_name: name, test_source: source
    ).run
    assert_equal true, result[:written]
    assert_equal test_path, result[:path]
    assert_equal 'passed', result[:syntax]
    assert_equal source, File.read(test_path)

    duplicate = ScoutCoder.job(:author_python_task_test, nil,
      task_name: name, test_source: source
    )
    duplicate.clean if duplicate.done?
    assert_raise(ParameterException) { duplicate.run }

    invalid_name = ScoutCoder.job(:author_python_task_test, nil,
      task_name: '../escape', test_source: source
    )
    assert_raise(ParameterException) { invalid_name.run }
  ensure
    File.delete(test_path) if test_path && File.file?(test_path)
    File.delete(task_path) if task_path && File.file?(task_path)
  end

  def test_define_python_task_rejects_symlinked_parent_directory
    Dir.mktmpdir('scoutcoder-python-task') do |root|
      outside = Dir.mktmpdir('scoutcoder-python-outside')
      FileUtils.mkdir_p(File.join(root, 'python'))
      File.symlink(outside, File.join(root, 'python', 'tasks'))
      name = "escape_probe_#{SecureRandom.hex(3)}"
      source = "import scout\ndef #{name}() -> str:\n    return 'ok'\nscout.task(#{name})\n"

      error = assert_raise(ArgumentError) do
        ScoutCoder::PythonTaskSupport.define_task(Struct.new(:libdir).new(root), name, source)
      end
      assert_match(/symlinked Python file parent/, error.message)
      assert_equal [], Dir.glob(File.join(outside, '*'))
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end

  def test_author_python_task_test_rejects_symlinked_parent_directory
    Dir.mktmpdir('scoutcoder-python-test') do |root|
      outside = Dir.mktmpdir('scoutcoder-python-outside')
      tasks = File.join(root, 'python', 'tasks')
      FileUtils.mkdir_p(tasks)
      File.write(File.join(tasks, 'escape_probe.py'), 'task source')
      File.symlink(outside, File.join(root, 'python', 'test'))

      error = assert_raise(ArgumentError) do
        ScoutCoder::PythonTaskSupport.write_test(root, 'escape_probe', "import unittest\n")
      end
      assert_match(/symlinked Python file parent/, error.message)
      assert_equal [], Dir.glob(File.join(outside, '*'))
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end
end
