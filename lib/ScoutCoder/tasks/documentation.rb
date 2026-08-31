module ScoutCoder
  REPOS=['scout-gear', 'scout-essentials', 'scout-camp', 'scout-ai', 'scout-rig']

  helper :repo_dir do |repo|
    Path.setup File.join(ENV['HOME'], 'git', repo)
  end

  # ScoutCoder: workflow `libdir` points at `<workflow root>/lib` for standard
  # checkout layouts (`<root>/workflow.rb` + `<root>/lib/<Name>/`).
  # `Workflow.extended` derives it with `Path.caller_lib_dir`, which walks up
  # from the loaded `workflow.rb` until it finds a directory containing `lib`,
  # `bin` or `README.md`. Therefore the README.md, doc*/ and research/ of a
  # workflow live at the PARENT of `wf.libdir`. If libdir already resolved to
  # the checkout root (single-file / non-standard workflow) it is used as is.
  helper :doc_root do |name|
    dir = repo_dir(name)
    return dir if dir.exists?

    begin
      wf = Misc.with_env('SCOUT_WORKFLOW_AUTOINSTALL', 'false'){ Workflow.require_workflow name }
    rescue ScoutException, RuntimeError
      # ScoutCoder: Workflow.require_workflow raises a plain RuntimeError
      # ("Workflow ... not found" / "Workflow repo does not exist") when it
      # cannot resolve a name, NOT a ScoutException. We convert it to a
      # controlled ParameterException here.
      raise ParameterException, "Unknown repo or workflow: #{name}"
    end
    raise ParameterException, "Unknown repo or workflow: #{name}" if wf.nil?

    libdir = wf.libdir
    raise ParameterException, "Unknown repo or workflow: #{name}" if libdir.nil?

    libdir = Path.setup(libdir.to_s)
    libdir.basename == 'lib' ? libdir.dirname : libdir
  end

  # ScoutCoder: the ORIGINAL code used `f.relative_to repo_dir(repo).doc` to
  # strip the doc* directory prefix. `Path#doc` there is NOT a file extension
  # suffix: Path uses method_missing to join a DIRECTORY named `doc` (i.e.
  # `repo_dir/doc`), and `relative_to` then produces paths relative to
  # `repo_dir/doc`, hiding the `doc/` prefix in the returned identifiers.
  # `doc_files` reproduces that identifier scheme (path relative to the
  # containing doc* dir itself, so `doc/user/Cookbook.md` ->
  # `user/Cookbook.md`) and extends it: README.md keeps its literal name and
  # research files are prefixed with `research/`.
  helper :doc_files do |root|
    identifiers = {}

    identifiers['README.md'] = root['README.md'] if root['README.md'].exists?

    root.glob('doc*/**/*.md').each do |file|
      top = file.relative_to(root).to_s.split(File::SEPARATOR).first
      identifiers[file.relative_to(root[top]).to_s] = file
    end

    research = root['research']
    root.glob('research/**/*.md').each do |file|
      identifiers["research/#{file.relative_to(research).to_s}"] = file
    end

    identifiers
  end

  task :help_list_repos => :array do
    REPOS
  end

  # ScoutCoder: `:string` inputs whose value matches an EXISTING filename in
  # the cwd are auto-loaded as file content by Task.format_input, so
  # `document: 'README.md'` would silently become the README text.
  # `nofile: true` keeps these inputs as literal strings.
  input :repo, :string, 'Repository or workflow of inquire', nil, required: true, nofile: true
  task :help_list_repo_documents => :array do |repo|
    doc_files(doc_root(repo)).keys.sort
  end

  input :repo, :string, 'Repository or workflow of inquire', nil, required: true, nofile: true
  input :document, :string, 'Document to retrieve', nil, required: true, nofile: true
  task :help_get_repo_document => :text do |repo, document|
    root = doc_root(repo)
    identifiers = doc_files(root)

    file =
      if document == 'README.md'
        root['README.md'].exists? ? root['README.md'] : nil
      else
        identifiers[document]
      end

    file ||= root.glob("doc*/**/#{document}").first
    file ||= root[document] if document.start_with?('research/', 'doc/')
    file ||= root.glob("research/**/#{document}").first

    if file.nil? || !Path.setup(file).exists?
      available = identifiers.keys.sort
      hint = available.any? ? " (available: #{available.first(10).join(', ')})" : ''
      raise ParameterException, "Not found #{document} in #{repo}#{hint}"
    end

    file.read
  end

  task :help_overview => :text do 
    agent = self.agent
    agent.system <<-EOF
You are a software documentation agent. You
generate documentation for use by AI agents.
    EOF

    agent.user <<-EOF
Write a guide into
the available documentation for the Scout framework.
The Scout framework covers many topics that can
be useful for agents developing or understanding code.
This guide should help agents find the right 
documentation files to understand particular pieces of
code. Next I will provide you the different repo
documents. Please return the guide in markdown document
with no extra commentary.
    EOF

    REPOS.each do |repo|
      agent.user <<-EOF
# Repo #{repo}
      EOF
      agent.file repo_dir(repo)['README.md'] if repo_dir(repo)['README.md'].exists?
      repo_dir(repo).glob('doc*/**/*.md').each do |file|
        agent.file file
      end
    end

    agent.chat
  end

  input :workflow, :string, 'Workflow for which to return documentation'
  extension 'md'
  task :help_workflow => :text do |workflow|
    wf = Misc.with_env('SCOUT_WORKFLOW_AUTOINSTALL', 'false'){ Workflow.require_workflow workflow }
    wf.documentation_markdown
  end

  # ScoutCoder: workflow enumeration must NEVER trigger network autoinstall.
  # `Workflow.installed_workflows` scans the `workflows` subtree of every
  # Scout pathmap (`Path.setup('workflows').glob_all('*')`), e.g.
  # `<cwd>/workflows` and `~/.scout/workflows`, so it is purely local. We
  # union it with already-loaded `Workflow.workflows` (modules loaded in this
  # process, e.g. ScoutCoder itself) and sort/dedup so ScoutCoder is always
  # listed even when its checkout is not reachable from any pathmap.
  task :help_list_workflows => :array do
    installed = (Workflow.installed_workflows rescue [])
    loaded = Workflow.workflows.collect{|wf| wf.name.to_s }
    (installed + loaded).uniq.sort
  end

  export :help_list_repos, :help_list_repo_documents, :help_get_repo_document, :help_overview, :help_workflow, :help_list_workflows
end
