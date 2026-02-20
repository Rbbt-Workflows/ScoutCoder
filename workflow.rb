require 'scout'
require 'scout-ai'

Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'

Workflow.require_workflow "ComputerUse"

module ScoutCoder
  extend Workflow

  def self.prompts
    Scout.share.prompts
  end

  @endpoints = Scout.etc.AI.glob_names("*")
  self.singleton_class.attr_accessor :endpoints

  helper :agent do |name="ScoutCoder",options={}|
    if name
      LLM::Agent.load_agent name, **options
    else
      options = IndiferentHash.add_defaults options, start_chat: Chat.setup(LLM.chat(Scout.start_chat.find))
      LLM.agent **options
    end
  end
end

require 'ScoutCoder/tasks/documentation.rb'
require 'ScoutCoder/tasks/explore.rb'
require 'ScoutCoder/tasks/develop.rb'

ScoutCoder.include_workflow ComputerUse

#ScoutCoder.all_exports.clear
#ScoutCoder.synchronous_exports.clear
#ScoutCoder.asynchronous_exports.clear
#ScoutCoder.exec_exports.clear
#ScoutCoder.export_exec :write, :read, :list_directory, :patch, :bash, :ruby, :python, :search
#ScoutCoder.export :explore_directory_structure, :summarize_file, :explain_code
#ScoutCoder.export :help_list_repos, :help_list_repo_documents, :help_get_repo_document, :documentation_overview

