module ScoutCoder
  REPOS=['scout-gear', 'scout-essentials', 'scout-camp', 'scout-ai', 'scout-rig']

  helper :repo_dir do |repo|
    Path.setup File.join(ENV['HOME'], 'git', repo)
  end

  desc 'List all repos'
  task :help_list_repos => :array do
    REPOS
  end

  desc 'List documents about a repo'
  input :repo, :select, 'Repo of inquire', nil, required: true, select_options: REPOS
  task :help_list_repo_documents => :array do |repo|
    repo_dir(repo).glob_names('doc*/*')
  end

  desc 'Get repo document'
  input :repo, :select, 'Repo of inquire', nil, required: true, select_options: REPOS
  input :document, :string, 'Document to retrieve', nil, required: true
  task :help_get_repo_document => :text do |repo, document|
    file = repo_dir(repo).glob("doc*/#{document}").first
    raise ParameterException, "Not found #{document} in #{repo}" if file.nil?
    file.read
  end

  task :documentation_overview => :text do 
    agent = self.agent
    agent.system <<-EOF
You are a software documentation agent. You
generate documentation for use by AI agents.
    EOF

    agent.user <<-EOF
Write a guide into
the available documentation for the Scout framework.
The Scout framework covers many topics that can
be useful to agents developing or understanding code.
This guide should help agents find the right 
documentation files to understand particular pieces of
code. Next I will provide you with the different repo
documents. Please return the guide in markdown document
with no extra commentary.
    EOF
    REPOS.each do |repo|
      agent.user <<-EOF
# Repo #{repo}
      EOF
      repo_dir(repo).glob('doc*/*').each do |file|
        agent.file file
      end
    end

    agent.chat
  end

  export :help_list_repos, :help_list_repo_documents, :help_get_repo_document, :documentation_overview
end
