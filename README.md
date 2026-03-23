ScoutCoder is an AI-assisted Scout workflow for retrieving framework documentation, exploring project files, and coordinating multi-agent development work over a local codebase.

The workflow combines three complementary capabilities. First, it exposes documentation lookup tasks for the Scout ecosystem, backed by local clones of the `scout-gear`, `scout-essentials`, `scout-camp`, `scout-ai`, and `scout-rig` repositories under `~/git`. Second, it provides project-understanding tasks that can summarize files, explain code, and generate a navigable description of a directory. Third, it contains agentic planning and implementation tasks that turn a natural-language request into a plan and then into delegated work across specialized prompts.

ScoutCoder is also structured as an agent directory. In `workflow.rb`, the `agent` helper either loads a named agent such as `ScoutCoder` or creates a fresh ad hoc agent seeded from the local `start_chat` file. The prompt templates under `share/prompts/` specialize the behavior of developer, supervisor, planner, and markdown-returning agents. This makes the workflow useful both as a normal Scout workflow and as a tool bundle for LLM-driven agents.

The workflow includes the `ComputerUse` workflow, so the same workflow instance also exposes practical file, search, execution, conversion, and patching tools such as `read`, `write`, `list_directory`, `patch`, `ruby`, `python`, `playwright`, `html2md`, and `pdf2md`. In practice, the ScoutCoder-specific tasks rely on these inherited utilities to inspect a repository and to produce reports or code changes without requiring a separate helper workflow.

A few small examples illustrate the intended use:

```ruby
require './workflow'

repos = ScoutCoder.job(:help_list_repos).run

docs = ScoutCoder.job(:help_list_repo_documents, nil,
  repo: 'scout-gear'
).run

text = ScoutCoder.job(:help_get_repo_document, nil,
  repo: 'scout-gear',
  document: 'Workflow.md'
).run

summary = ScoutCoder.job(:summarize_file, nil,
  file: 'workflow.rb'
).run

guide = ScoutCoder.job(:explore_directory_structure, nil,
  directory: '.'
).run

plan = ScoutCoder.job(:plan, nil,
  prompt: 'Add a new task and document it'
).run
```

```bash
scout workflow task ScoutCoder explain_code \
  --files workflow.rb,lib/ScoutCoder/tasks/documentation.rb

scout workflow task ScoutCoder help_workflow \
  --workflow ScoutCoder

scout workflow task ScoutCoder list_directory \
  --directory .
```

The documentation tasks are most useful when an agent needs Scout-specific context before touching code. The exploration tasks are useful when the agent first needs to understand an unfamiliar repository. The planning and implementation tasks are higher-level orchestration steps intended to break a request into work and then execute that work with agent assistance.

# Tasks

## help_list_repos
List the Scout documentation repositories known to ScoutCoder

This task returns the fixed repository list used by the rest of the documentation helpers. At the time of writing it includes `scout-gear`, `scout-essentials`, `scout-camp`, `scout-ai`, and `scout-rig`.

Use this task as the discovery step when an agent knows it needs framework documentation but does not yet know where that documentation lives. The returned values are valid inputs for `help_list_repo_documents` and `help_get_repo_document`.

## help_list_repo_documents
List the documentation files available in one Scout repository

The `repo` input selects one repository from the known set, and the task returns the names of files found under `doc*/*` in that repository. In other words, it exposes the documentation index for that repo rather than returning file contents.

This is the normal follow-up to `help_list_repos`. Agents can inspect the available document names first and then request the specific files that match the concepts they need, such as `Workflow.md`, `TSV.md`, `CMD.md`, or `Agent.md`.

## help_get_repo_document
Return the contents of a documentation file from one Scout repository

The task takes a `repo` and a `document` name, locates the first matching file under `doc*/`, and returns the full text of that document. If the requested file cannot be found it raises a `ParameterException`, which makes failures explicit and easy for an agent to recover from.

This is the lowest-level documentation lookup task. Use it when an agent already knows the exact document it needs and wants the raw markdown to read or quote.

## help_overview
Generate a guide to the available Scout framework documentation

This task builds a synthetic overview by reading all documentation files from the known Scout repositories and asking an agent to produce a markdown guide for other agents. The result is not a static hand-written file; it is generated from the currently available documentation and can evolve as the source repositories evolve.

In practice this is a good first stop when an agent has a broad question such as where to learn about workflows, entities, TSV processing, command execution, or LLM integration. The answer should help narrow the search before calling `help_get_repo_document` on specific files.

## help_workflow
Return the markdown documentation for a workflow

The `workflow` input names any workflow that can be loaded through `Workflow.require_workflow`. The task then calls `documentation_markdown` on that workflow and returns the result as markdown text.

This is useful both for introspection and for tool discovery. For example, an agent can read the documentation for `ScoutCoder` itself, inspect the inherited `ComputerUse` workflow, or query the docs of another installed workflow before interacting with it.

## summarize_file
Summarize one file

This is the lightest-weight repository understanding task. It validates that the given `file` exists and is not a directory, attaches it to a fresh agent, and asks for a summary.

Use `summarize_file` when a file is probably relevant but you do not yet want a line-by-line explanation. It is especially useful before deciding whether to read the full file or to include it in a broader `explain_code` request.

## explain_code
Read one or more files and explain the code they contain

The `files` input is a path array. Each file is validated before being attached to the agent, and the agent is asked to explain the code and to consult Scout documentation when that helps interpret framework-specific constructs.

This task is best used for related source files that make more sense together than in isolation, for example a workflow file plus one or more task files. Compared with `summarize_file`, the goal here is understanding structure, responsibilities, and implementation details rather than producing a brief synopsis.

## explore_directory_structure
Explore a directory and return a markdown guide to its contents

This task is designed for first-contact exploration of a repository or analysis directory. The agent is instructed to use inherited tools such as `list_directory`, `read`, `file_stats`, `summarize_file`, and `explain_code` to inspect the tree efficiently and to avoid loading more context than necessary.

The implementation seeds the agent with a recursive directory listing including stats, asks it to plan a concise guide for other agents, and then asks for a final markdown document. The task also saves the underlying chat transcript to the step files area, which can be helpful when reviewing how the report was produced.

## plan
Produce a structured implementation plan for a prompt

The `prompt` input is a free-text request describing something to build or change. The task creates an agent, asks it to act specifically as a planner, and requests a three-part answer with `Overview`, `Approach`, and `Steps`.

This task is useful when a request is still ambiguous or large enough that it should be decomposed before any coding starts. The `Approach` section is meant to connect the request with the actual project structure, while the `Steps` section is intended to be actionable enough for delegated implementation work.

## implement
Coordinate agent-assisted implementation of a prompt

This task depends on `plan`, so it first obtains a structured plan for the same request. It then assembles a small agent hierarchy: a developer agent with workflow tools and the developer prompt, a supervisor agent that delegates to the developer, and a top-level agent that delegates to the supervisor.

The planned steps are passed to the top-level agent together with instructions to use `./doc/` for any supporting documentation files that help downstream agents complete the work. Conceptually, `implement` is the highest-level task in the workflow: rather than answering a question directly, it orchestrates a multi-agent execution strategy around a previously generated plan.

## current_time
Return the current system time as plain text

This small utility task is mainly useful for sanity checks, timestamp comparisons, or lightweight tool testing. It has no inputs and returns the current time as a string.

Because it is simple and side-effect free, it is often used to verify that a tool call path is working before invoking more substantial tasks.

## pwd
Return the current working directory

This task reports the working directory that defines the safe root for filesystem-oriented tasks inherited from `ComputerUse`. In ScoutCoder, tasks such as `read`, `write`, `delete`, `search`, and `list_directory` are constrained to operate under this directory.

Agents should often call `pwd` early when they need to reason about relative paths or confirm the sandbox root they are allowed to modify.

## list_directory
List files and directories under a path

The required `directory` input selects the subtree to inspect. The optional `recursive` and `stats` inputs control whether the listing descends into subdirectories and whether file metadata is included.

This is the primary discovery task for repository exploration. Use it before reading files so that an agent has a map of the project and can decide which paths are likely to matter.

## file_stats
Return basic metadata for one file

The `file` input identifies a path under the allowed root, and the task returns basic information such as file type, size, line count, and modification time. It is especially useful for deciding whether a file is small enough to read directly or should be summarized first.

When exploring unfamiliar repositories, `file_stats` helps agents control context size and choose the right follow-up task.

## read
Read all or part of a file

This task reads a file and returns text from either the head or the tail. The `limit`, `file_end`, and `start` inputs make it possible to inspect large files incrementally instead of loading them whole.

For agentic workflows this is usually the safest primitive for direct content access. It works well together with `file_stats`, `search`, and `summarize_file`.

## search
Search plain-text files for a query string

The `path` input selects the directory to search, `query` is the literal string to match, and `max_results` can be used to bound the number of returned paths. The task searches file contents rather than filenames and skips binary files.

This is a good way to find definitions, prompt fragments, or configuration values before reading any specific file. It is particularly effective for locating task names, helper methods, or references to workflow-specific concepts.

## write
Write a text file under the working directory

The task takes a relative `file` path and a `content` string, validates that the target remains under the workflow root, and writes the file. Existing files can be overwritten.

Use `write` for creating new files or replacing complete file contents. For small edits to existing files, `patch` is usually the better fit because it preserves surrounding content and makes intent clearer.

## delete
Delete a file or directory under the working directory

The `file` input identifies the target path. If the path is a directory, deletion is recursive; the same path safety checks used by the other filesystem tasks are applied here as well.

This task is the correct way to remove files or directories. Do not try to delete files through `patch`, which is intended only for updates to existing file contents.

## patch
Apply a patch to an existing file

This task accepts unified diffs and ChatGPT-style patch blocks, normalizes them, tries to detect the appropriate strip level, and applies the patch from the repository root. It is designed for AI agents that need to update existing files while keeping the change localized and inspectable.

Use `patch` only for modifications to files that already exist. If the goal is to add a file, prefer `write`; if the goal is to remove one, prefer `delete`. The `dry_run` option is especially useful when an agent is iterating on a patch and wants diagnostics before changing the repository.

## bash
Run a bash command in the project sandbox

The required `cmd` input is a shell command string. The task executes it in the sandboxed environment when available and returns a JSON object containing standard output, standard error, and exit status.

This is the broadest execution primitive and is useful for ad hoc inspection, command-line tooling, and quick repository checks. For language-specific snippets, the dedicated `ruby`, `python`, and `r` tasks are often more convenient.

## ruby
Run Ruby code or a Ruby file

You can provide inline Ruby with the `code` input or point at a script file with the `file` input. The task returns a JSON object with standard output, standard error, and exit status.

This is the natural execution task when exploring or testing Scout workflows, because it lets an agent load `workflow.rb`, instantiate jobs, or inspect task metadata directly from Ruby.

## python
Run Python code or a Python file

This task mirrors `ruby` but for Python. It accepts inline code or a script path and returns execution results as JSON.

It is useful for lightweight data processing, format conversion, or validation steps when Python is the easiest tool for the job.

## r
Run R code or an R script

This task executes inline R or an R file and returns the standard output, standard error, and exit status. It is mainly intended for repositories that include analysis components or tasks that are easier to express in R.

In mixed-code projects, this gives agents a direct way to validate or inspect R-based assets without leaving the workflow environment.

## playwright
Run Playwright tests against a URL

The task accepts inline Playwright test code or a path to an existing Playwright test file, runs it with `npx playwright test`, and stores run artifacts under `.playwright/`. Optional inputs control headless execution, tracing, video, timeout, and extra command-line arguments.

This is the preferred task for browser-level validation of web applications. It is particularly useful after code changes when an agent wants a repeatable UI check rather than a manual inspection.

## html2md
Convert HTML or an HTML URL to markdown

The required `html` input can contain raw HTML or a remote URL. The task converts the result to markdown using `html2markdown`, fetching the content first when a URL is supplied.

This task is useful when web pages or generated HTML documents need to be fed into text-oriented tools such as summarizers, search steps, or RAG pipelines.

## html_query
Query HTML content through the excerpt and RAG pipeline

This task is a convenience wrapper that uses `html2md` as the text source before chunking and querying. In practice it lets an agent search HTML-derived content without manually invoking the intermediate conversion and indexing tasks.

Use it when the starting point is a web page or HTML snippet and the goal is to retrieve the most relevant passages for a question.

## pdf2md_full
Convert a PDF to markdown with images preserved in the markdown output

The `pdf` input points to a PDF file, which is processed with `docling`. The generated markdown is written to the task area and becomes the primary result for the step.

This is the most faithful PDF conversion task in the workflow. Use it when image placeholders or the full markdown structure are useful for later processing.

## pdf2md_no_images
Convert a PDF to markdown and drop image placeholder lines

This task depends on `pdf2md_full` and then removes lines that begin with the image placeholder marker. The result is usually cleaner when the PDF is being processed for text understanding rather than layout reconstruction.

It is a better default than `pdf2md_full` for most language-model workflows, because it strips a common source of noise while preserving the text content.

## pdf2md
Alias to the image-stripped PDF-to-markdown conversion

This is the convenient public name for the cleaner PDF conversion path. In most cases agents should call `pdf2md` instead of deciding between the underlying PDF conversion variants themselves.

Use `pdf2md_full` only when the full conversion output, including image markers, is specifically needed.

## excerpts
Split markdown text into excerpts

This task takes markdown text and breaks it into chunks according to the selected strategy, such as paragraphs, sentences, or sliding windows. The chunking parameters let an agent trade off locality and context size.

It is the preprocessing step behind the workflow's simple RAG pipeline. Use it when long documents need to be searched semantically rather than read sequentially.

## rag
Build a retrieval index from excerpts

After excerpts have been produced, this task embeds them with the chosen embedding model and saves an `LLM::RAG` index. The result is a compact retrieval structure that can later be queried for relevant passages.

This is useful when a document or collection is large enough that repeated semantic lookup is more efficient than repeated full-text reading.

## query
Search a RAG index for the best matching passages

The required `prompt` input is the text to match, and `num` controls how many excerpts are returned. The task produces a JSON array of the best-scoring excerpt texts.

Together with `excerpts` and `rag`, this provides a lightweight semantic retrieval stack inside the workflow.

## pdf_query
Query PDF content through the PDF conversion and RAG pipeline

This task is a convenience wrapper for the common case where the source material is a PDF and the desired output is a short list of relevant passages. It saves the caller from manually chaining PDF conversion, chunking, indexing, and retrieval.

Use it when you need answer-oriented access to a PDF rather than a full markdown conversion.

## searxng
Run a web search through a configured SearXNG instance

The `query` input supplies the search string, while optional inputs allow control over result count, language, categories, engines, safe-search, time range, and endpoint path. The task relies on a configured SearXNG endpoint and returns structured search results as JSON.

This is ScoutCoder's outward-facing web lookup task. It is useful when the needed information is not in the local repository or in the local Scout documentation set and an agent needs a controlled way to search the web.
