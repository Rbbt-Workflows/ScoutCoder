module ScoutCoder
  REPOS=['scout-gear', 'scout-essentials', 'scout-camp', 'scout-ai']

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
end
