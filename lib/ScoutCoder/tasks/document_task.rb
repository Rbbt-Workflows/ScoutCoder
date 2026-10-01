module ScoutCoder

  desc "Add or replace a task entry in the ScoutCoder README.md Tasks section.\n\nInputs: `task_name` and `documentation`. Replaces the existing `## <task_name>` entry, or appends a new entry at the end of the `# Tasks` section. The documentation is Markdown body text placed beneath the generated heading."
  input :task_name, :string, 'Name of the task to document', nil, required: true, nofile: true
  input :documentation, :text, 'Markdown documentation for the task entry', nil, required: true

  module TaskReadme
    module_function

    def replace_task_entry(readme, task_name, documentation)
      name = task_name.to_s.strip
      raise ParameterException, 'task_name must not be empty' if name.empty?
      raise ParameterException, 'task_name must not contain a newline' if name.match?(/[\r\n]/)
      body = documentation.to_s.strip
      raise ParameterException, 'documentation must not be empty' if body.empty?

      entry = "## #{name}\n\n#{body}\n"
      lines = readme.lines
      tasks_index = lines.index { |line| line.match?(/^# Tasks\s*$/) }
      raise ParameterException, 'README.md has no # Tasks section' unless tasks_index

      section_end = ((tasks_index + 1)...lines.length).find { |index| lines[index].match?(/^#\s+[^#]/) } || lines.length
      entry_indices = ((tasks_index + 1)...section_end).select do |index|
        lines[index].match?(/^## #{Regexp.escape(name)}\s*$/)
      end
      if entry_indices.any?
        start_index = entry_indices.first
        end_index = ((start_index + 1)...section_end).find { |index| lines[index].match?(/^##\s+/) } || section_end
        lines[start_index...end_index] = [entry, "\n"]
      else
        insertion = section_end
        insertion -= 1 while insertion > tasks_index + 1 && lines[insertion - 1].strip.empty?
        # Replace any trailing section whitespace too, so the new entry gets
        # exactly one blank line before and after it.
        lines[insertion...section_end] = ["\n", entry, "\n"]
      end
      lines.join
    end
  end

  task :document_task => :string do |task_name, documentation|
    readme_path = File.expand_path('../../../README.md', __dir__)
    unless File.file?(readme_path)
      raise ParameterException, "README.md not found at #{readme_path}"
    end
    original = File.read(readme_path)
    updated = TaskReadme.replace_task_entry(original, task_name, documentation)
    File.write(readme_path, updated)
    "Documented #{task_name} in #{readme_path}"
  end

export :document_task

end
