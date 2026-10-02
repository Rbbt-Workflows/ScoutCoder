require 'scout'
require 'scout-ai'


Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'
#require_relative 'lib/ScoutCoder/LiveWorkflow'

module ScoutCoder
  extend Workflow
  extend LiveWorkflow

end

require_relative 'lib/ScoutCoder/tasks/documentation'
require_relative 'lib/ScoutCoder/tasks/document_task'
require_relative 'lib/ScoutCoder/tasks/workflow_tools'
require_relative 'lib/ScoutCoder/tasks/task_test_tools'
require_relative 'lib/ScoutCoder/tasks/helper_tools'
require_relative 'lib/ScoutCoder/tasks/entity_tools'
require_relative 'lib/ScoutCoder/tasks/list_entities'
require_relative 'lib/ScoutCoder/helper_test_support'
