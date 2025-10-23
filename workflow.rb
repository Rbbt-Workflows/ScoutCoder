require 'scout'
require 'scout-ai'

Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'

Workflow.require_workflow "ComputerUse"

module ScoutCoder
  extend Workflow



  helper :agent do
    LLM.agent workflow: ScoutCoder, start_chat: LLM.chat(Scout.start_chat.find)
  end

  desc 'Read the files and explain the code'
  input :files, :path_array, 'List of files to examine', nil, required: true
  task :explain_code => :text do |files|
    agent = self.agent
    files.each do |file|
      raise ParameterException, "File not readable #{file}" unless Open.exists?(file) && ! Open.directory?(file)
      agent.file file
    end

    agent.user <<-EOF
Please explain the code found in the files
    EOF

    agent.chat
  end

  desc 'Read the file and make a summary'
  input :file, :path, 'File to examine', nil, required: true
  task :summarize_file => :text do |file|
    raise ParameterException, "File not readable #{file}" unless Open.exists?(file) && ! Open.directory?(file)
    agent = self.agent
    agent.file file

    agent.user <<-EOF
Summarize this file
    EOF

    agent.chat
  end

  desc 'Explore a directory structure and return a description of the contents'
  input :directory, :path, 'Directory to traverse', nil, required: true
  task :explore_directory_structure => :text do |directory|
    agent = self.agent

    agent.user <<-EOF

Use the tools list_directory, read, file_stats, summarize_file, etc. to
traverse the directory structure under directory #{File.expand_path directory}
and return a description of what you find. You may use the repo documentation
to help you understand what you find in the files

Try not to load into context large files, instead use the summarize_file tool.

    EOF
     
    agent.user 'Start by listing the directory recursively'

    #agent.task ComputerUse, :list_directory, directory: directory, recursive: false, stats: true

    #agent.user 'Now examine the results and proceed from here. Return a description that can help other AI agents find what they need'

    agent.user 'Identify interesting files read them or summarize them, depending on their size'

    agent.user 'Make use of the tools that you were provided'

    agent.user 'Return a description that can help other AI agents find what they need'

    agent.chat
  end
  
  export :explain_code, :summarize_file
end

#require 'ScoutCoder/tasks/documentation.rb'

#require 'rbbt/knowledge_base/ScoutCoder'
#require 'rbbt/entity/ScoutCoder'

