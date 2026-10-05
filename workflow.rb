require 'scout'
require 'scout-ai'
require 'scout/workflow/python'


Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'
#require_relative 'lib/ScoutCoder/LiveWorkflow'

module ScoutCoder
  extend Workflow
  extend LiveWorkflow

  # PythonWorkflow runs Python task files via ScoutPython's subprocess API.
  # Add scout-rig's bundled Python package so `import scout` resolves.
  scout_rig_python = File.expand_path('~/git/scout-rig/python')
  ScoutPython.add_path(scout_rig_python) unless ScoutPython.paths.include?(scout_rig_python)

  extend PythonWorkflow
  @python_task_dir = Path.setup(File.expand_path('python/tasks', __dir__))
  load_python_tasks
end

require_relative 'lib/ScoutCoder/tasks/documentation'
require_relative 'lib/ScoutCoder/tasks/document_task'
require_relative 'lib/ScoutCoder/tasks/workflow_tools'
require_relative 'lib/ScoutCoder/tasks/task_test_tools'
require_relative 'lib/ScoutCoder/tasks/python_task_tools'
require_relative 'lib/ScoutCoder/tasks/helper_tools'
require_relative 'lib/ScoutCoder/tasks/entity_tools'
require_relative 'lib/ScoutCoder/tasks/list_entities'
require_relative 'lib/ScoutCoder/helper_test_support'

