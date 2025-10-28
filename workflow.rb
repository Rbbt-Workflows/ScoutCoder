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

  helper :agent do |options={}|
    model = config :model
    endpoint = config :endpoint
    workflow = config :workflow, default: ScoutCoder
    options[:endpoint] = endpoint unless options.include?(:endpoint) || endpoint.nil?
    options[:model] = endpoint unless options.include?(:model) || model.nil?
    workflow = nil if workflow == 'none'
    LLM.agent **options.merge(workflow: workflow, start_chat: Chat.setup(LLM.chat(Scout.start_chat.find)))
  end
end

require 'ScoutCoder/tasks/documentation.rb'
require 'ScoutCoder/tasks/explore.rb'
require 'ScoutCoder/tasks/develop.rb'

ScoutCoder.include_workflow ComputerUse

#require 'rbbt/knowledge_base/ScoutCoder'
#require 'rbbt/entity/ScoutCoder'

