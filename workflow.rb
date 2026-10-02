require 'scout'
require 'scout-ai'


Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'

module ScoutCoder
  extend Workflow

end


require_relative 'lib/ScoutCoder/LiveWorkflow'
require_relative 'lib/ScoutCoder/tasks/documentation'
require_relative 'lib/ScoutCoder/tasks/document_task'
require_relative 'lib/ScoutCoder/tasks/workflow_tools'
require_relative 'lib/ScoutCoder/tasks/task_test_tools'
require_relative 'lib/ScoutCoder/tasks/helper_tools'
require_relative 'lib/ScoutCoder/tasks/entity_tools'
require_relative 'lib/ScoutCoder/tasks/list_entities'
require_relative 'lib/ScoutCoder/helper_test_support'

# Entity definitions must be loaded before property files so every property
# can register against an available entity module. The block below loads the
# lib entity files first, then extends LiveWorkflow, which loads share/tasks,
# share/helpers, share/entities and share/entity_properties in that order, and
# finally loads the lib entity property files. The combined order is lib
# entities -> share entities -> share properties -> lib properties: a
# share-draft property can register on a built-in lib entity, and a lib
# property can register on a share-draft entity. Sorting inside each glob
# makes the order deterministic both on startup and on
# Workflow.require_workflow(update: true).
module ScoutCoder
  entity_root = File.expand_path('lib/ScoutCoder/entity', __dir__)
  entity_files = Dir.glob(File.join(entity_root, '*.rb')).sort
  entity_files.each { |file| load file }

  # Load this checkout's authoring drafts from share/ (tasks, helpers,
  # entities, entity_properties, in that order). A no-op while those
  # directories hold no *.rb files.
  extend ScoutCoder::LiveWorkflow

  entity_property_files = Dir.glob(File.join(entity_root, '*', '**', '*.rb')).sort
  entity_property_files.each { |file| load file }
end
