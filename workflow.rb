require 'scout'
require 'scout-ai'


Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'

module ScoutCoder
  extend Workflow

end


require 'ScoutCoder/tasks/documentation'
require 'ScoutCoder/tasks/workflow_tools'

Scout.share.find(:current).tasks.glob('*.rb').each do |file|
  load file
end

#ScoutCoder.all_exports.clear
#ScoutCoder.synchronous_exports.clear
#ScoutCoder.asynchronous_exports.clear
#ScoutCoder.exec_exports.clear
#ScoutCoder.export_exec :write, :read, :list_directory, :patch, :bash, :ruby, :python, :search
#ScoutCoder.export :explore_directory_structure, :summarize_file, :explain_code
#ScoutCoder.export :help_list_repos, :help_list_repo_documents, :help_get_repo_document, :documentation_overview

