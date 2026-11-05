# Promoted task: documentation lives in README.md (## reload_workflow), not desc.
module ScoutCoder

  desc 'Reload a workflow checkout in the running process: purge $LOADED_FEATURES entries whose realpath falls under the checkout root (entrypoint included when cached), then re-evaluate workflow.rb so lib/ edits and promotions take effect immediately. Default root: the ScoutCoder checkout itself (its own lib/ edits are the live concern); pass root explicitly to reload any other workflow checkout. Returns a report (ok, root, entrypoint, purged list, reload mode, workflow module).'
  input :root, :string, 'OPTIONAL workflow checkout root (a directory containing workflow.rb); defaults to the ScoutCoder checkout root', nil, nofile: true
  task :reload_workflow => :json do |root|
    begin
      root = ScoutCoder::PATH_KIND_ROOT if root.nil? || root.to_s.empty?
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
  export :reload_workflow

end
