require 'scout'
require 'scout-ai'


Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'

module ScoutCoder
  extend Workflow

end


require_relative 'lib/ScoutCoder/tasks/document_task'
require_relative 'lib/ScoutCoder/tasks/workflow_tools'
require_relative 'lib/ScoutCoder/tasks/task_test_tools'
require_relative 'lib/ScoutCoder/tasks/helper_tools'
require_relative 'lib/ScoutCoder/helper_test_support'

Scout.share.find(:current).tasks.glob('*.rb').each do |file|
  load file
end

Scout.share.find(:current).helpers.glob('*.rb').each do |file|
  load file
end
