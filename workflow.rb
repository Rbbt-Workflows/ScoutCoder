require 'scout'
require 'scout-ai'
require 'scout/workflow/python'


Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'
#require_relative 'lib/ScoutCoder/LiveWorkflow'

module ScoutCoder
  extend Workflow
end

ScoutCoder.extend LiveWorkflow
ScoutCoder.extend PythonWorkflow

# Workflow-scoped path kinds for the scout-ai agent path engine. Must load
# after the module is extended so the constant lands on ScoutCoder itself;
# it is consumed by integrate_workflow_path_kinds(ScoutCoder) on
# whole-workflow `tool: ScoutCoder` incorporation.
require_relative 'lib/ScoutCoder/path_kinds' if Scout.root['workflow.rb'].find(:current).exists?
require_relative 'lib/ScoutCoder/tasks/documentation'
require_relative 'lib/ScoutCoder/tasks/document_task'
require_relative 'lib/ScoutCoder/tasks/workflow_tools'
require_relative 'lib/ScoutCoder/tasks/entity_tools'
require_relative 'lib/ScoutCoder/tasks/list_entities'
require_relative 'lib/ScoutCoder/tasks/test_runner_tools'
require_relative 'lib/ScoutCoder/tasks/probe_tools'
