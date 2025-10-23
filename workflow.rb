require 'scout'

Misc.add_libdir if __FILE__ == $PROGRAM_NAME

#require 'rbbt/sources/ScoutCoder'

module ScoutCoder
  extend Workflow


  REPOS=['scout-gear', 'scout-essentials', 'scout-camp', 'scout-ai']

  helper :repo_dir do |repo|
    Path.setup File.join(ENV['HOME'], 'git', repo)
  end

  helper :agent do
    LLM.agent workflow: ScoutCoder
  end

  desc 'List all repos'
  task :list_repos => :array do
    REPOS
  end

  desc 'List documents about a repo'
  input :repo, :select, 'Repo of inquire', nil, required: true, select_options: REPOS
  task :list_repo_documents => :array do |repo|
    repo_dir(repo).glob_names('doc*/*')
  end

  desc 'Get repo document'
  input :repo, :select, 'Repo of inquire', nil, required: true, select_options: REPOS
  input :document, :string, 'Document to retrieve', nil, required: true
  task :get_repo_document => :text do |repo, document|
    file = repo_dir(repo).glob("doc*/#{document}").first
    raise ParameterException, "Not found #{document} in #{repo}" if file.nil?
    file.read
  end

  desc 'Read the files and explain the code'
  input :files, :array, 'List of files to examine', nil, required: true
  task :explain_code => :text do |files|
    agent = agent
    files.each do |file|
      agent.file file
    end
    agent.user <<-EOF
Please explain the code found in the files
    EOF

    agent.chat
  end
  
  export :explain_code
  export :list_repo_documents, :get_repo_document
end

require 'ScoutCoder/tasks/documentation.rb'

#require 'rbbt/knowledge_base/ScoutCoder'
#require 'rbbt/entity/ScoutCoder'

