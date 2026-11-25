# Promoted task: documentation lives in README.md (## reload_workflow), not desc.
module ScoutCoder

  input :root, :string, 'Workflow checkout root (a directory containing workflow.rb); defaults to the current repo', 'current', nofile: true
  task :reload_workflow => :json do |root|
    begin
      root = Scout.root.find if root.nil? || root.to_s.empty? || root.to_s == 'current'
      report = ScoutCoder::WorkflowReload.reload_workflow!(root: root)
      # The module object is not JSON-serializable; name it for the report.
      report['workflow'] = report['workflow'].name
      report
    rescue ParameterException
      raise
    rescue StandardError => error
      raise ParameterException, "reload_workflow failed: #{error.class}: #{error.message}"
    end
  end
  export_exec :reload_workflow

end
