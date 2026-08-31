# ScoutCoder Help Tasks Reference

This document describes the documentation-oriented tasks exposed by the
ScoutCoder workflow, the inputs they accept, and how they resolve their
documentation sources. It is written for agents and developers who need to
understand or extend this tooling.

## Overview of the help tasks

All tasks live in `lib/ScoutCoder/tasks/documentation.rb`. They exist so that
other agents (and humans) can discover and read the documentation of the Scout
framework components without reimplementing lookup logic themselves.

The implementation distinguishes two kinds of documentation sources:

1. **Scout repositories** (Ruby gems / git checkouts such as `scout-gear`,
   `scout-ai`), addressed by repository name and located at
   `~/git/<repo-name>` (i.e. `ENV['HOME']/git/<name>`).
2. **Scout workflows** (e.g. `ComputerUse`, `ScoutCoder`, third-party
   workflows), addressed by workflow name and resolved through
   `Workflow.require_workflow`, whose checkout root is derived from the
   workflow module `libdir`.

Both kinds are treated uniformly: any Scout repo or any installed Scout
workflow is listed and inspected using the same tasks, and workflow checkouts
carry the same `README.md` + `doc*/` + `research/` documentation layout as the
repositories.

## help_list_repos

Returns the list of known Scout repository checkouts. This is the constant
`REPOS` hardcoded in the task file: `scout-gear`, `scout-essentials`,
`scout-camp`, `scout-ai`, and `scout-rig`. It takes no inputs and returns an
array of repo names.

This is the discovery entry point for repository sources: an agent normally
calls it first to learn which repository names are valid arguments for the
tasks below. Workflow sources are enumerated by `help_list_workflows` instead.

## help_list_repo_documents

Lists the markdown documents available for one source.

- Input `repo` (string, required, `nofile: true`): the name of a Scout
  repository under `~/git` or of any installed Scout workflow.
- Returns an array of document identifiers.

The source root is resolved by the `doc_root` helper: it first tries
`repo_dir(name)` (`~/git/<name>`) and uses it when that directory exists;
otherwise it loads the workflow with `Misc.with_env('SCOUT_WORKFLOW_AUTOINSTALL',
'false'){ Workflow.require_workflow name }` and derives the checkout root from
`wf.libdir` (the parent directory when `libdir` ends in `lib`, `libdir` itself
otherwise). If `require_workflow` raises, the error is converted to a
controlled `ParameterException` ("Unknown repo or workflow: <name>"); the same
exception is raised when the workflow or its `libdir` cannot be resolved.

The listing covers `README.md` plus every `*.md` file under the `doc*/`
subtrees plus every `*.md` file under `research/`. Identifiers follow the
`doc_files` scheme:

- `README.md` keeps its literal name;
- files under a `doc*` directory are identified by their path relative to that
  containing directory, so `doc/user/Cookbook.md` is listed as
  `user/Cookbook.md`;
- research files are prefixed with `research/`, e.g. `research/notes.md`.

This reproduces the legacy identifier behavior of the original code, which used
`f.relative_to repo_dir(repo).doc` to strip the doc* prefix. Note that `Path#doc`
there is not a filename extension suffix: `Path` uses `method_missing` to join
a DIRECTORY named `doc` (i.e. `repo_dir/doc`), so `relative_to` then produced
paths relative to `repo/doc`, hiding the `doc/` prefix. `doc_files` keeps the
same scheme for compatibility and extends it with the `README.md` and
`research/` cases.

## help_get_repo_document

Reads one document from one source.

- Input `repo` (string, required, `nofile: true`): source name, as above.
- Input `document` (string, required, `nofile: true`): document identifier, as
  produced by `help_list_repo_documents`.

After resolving the root with `doc_root` and building the `doc_files`
identifier map, the task walks a fallback chain and takes the first match:

1. the literal `root['README.md']` when `document` is `README.md`;
2. an exact match in the identifier map (`identifiers[document]`);
3. the first `root.glob("doc*/**/#{document}")` match;
4. the direct path `root[document]` when `document` starts with `research/`
   or `doc/`;
5. the first `root.glob("research/**/#{document}")` match.

The first hit is checked for existence and returned with `file.read`. When no
step matches (or the candidate does not exist) the task raises a
`ParameterException` ("Not found <document> in <repo>") whose message lists up
to 10 available document identifiers, which is a controlled, expected failure
that callers should handle.

## help_overview

Generates a natural-language guide to the available Scout documentation using
an LLM agent. It attaches `README.md` (when present) plus every file matched
by `doc*/**/*.md` for each known repo, then asks the agent to write an overview
for use by other agents.

Because this issues a full LLM call over all documentation files, it is
expensive; it is usually not worth running in tests or CI, and a lightweight
deterministic check of listing/retrieval tasks is preferred for regression
purposes. Note that this task still aggregates only the `REPOS` list; it does
not cover workflow sources.

## help_workflow

Returns the documentation of any installed Scout workflow.

- Input `workflow` (string): workflow name (e.g. `ComputerUse`).
- Output is markdown text with the `.md` extension.

The workflow is loaded with `SCOUT_WORKFLOW_AUTOINSTALL=false` through
`Workflow.require_workflow`, so it must already be available locally (in the
workflow directory / on the load path); auto-downloading is intentionally
disabled. The returned text is `wf.documentation_markdown`, i.e. the content of
the workflow's `workflow.md` or `README.md` next to its `libdir`.

## help_list_workflows

Lists the workflows installed and available to ScoutCoder.

- No inputs; returns a sorted, deduplicated array of workflow names.

The result is the union of `Workflow.installed_workflows` and
`Workflow.workflows.collect{|wf| wf.name.to_s }`. `installed_workflows` scans
the `workflows` subtree of every Scout pathmap
(`Path.setup('workflows').glob_all('*')`), e.g. `<cwd>/workflows` and
`~/.scout/workflows`, so it is purely local. Unioning with the modules already
loaded in the current process guarantees that ScoutCoder itself is listed even
when its checkout is not reachable from any pathmap. The `installed_workflows`
call is wrapped in `rescue []`, so the task never crashes, and no network
autoinstall is ever triggered.

Any returned name is usable as the `repo` input of `help_list_repo_documents`
and `help_get_repo_document`, giving access to that workflow's own `README.md`,
`doc*/`, and `research/` documentation.

## How sources are resolved

- **Repos**: `repo_dir(repo)` builds the path `~/git/<repo>`. When that
  directory exists it is used directly as the documentation root, regardless of
  whether the name also names a workflow.
- **Workflows**: `Workflow.require_workflow` locates the workflow file (name,
  snake_case, or camel_case under the `workflows` path), loads it with
  `SCOUT_WORKFLOW_AUTOINSTALL=false`, and yields the workflow module with its
  `libdir` set to the `lib` directory of the checkout for standard layouts
  (`<root>/workflow.rb` + `<root>/lib/<Name>/`). `doc_root` therefore walks one
  level up from `libdir` (`libdir.dirname`) to reach the checkout root and its
  `README.md`, `doc*/`, and `research/`; if `libdir` already resolved to the
  checkout root (single-file / non-standard workflow) it is used as is.
- **Error handling**: `Workflow.require_workflow` raises a plain `RuntimeError`
  ("Workflow ... not found" / "Workflow repo does not exist") when it cannot
  resolve a name, not a `ScoutException`. `doc_root` rescues both and converts
  them into a controlled `ParameterException` ("Unknown repo or workflow:
  <name>"), and also raises it when the loaded workflow or its `libdir` is nil.
- **Identifier scheme**: listings enumerate `README.md`, `doc*/**/*.md`, and
  `research/**/*.md` for both kinds of source, so repository and workflow
  documentation are interchangeable inputs for the help tooling.

## Why the repo/document inputs use `nofile: true`

`:string` inputs whose value matches an EXISTING filename in the current
working directory are auto-loaded as file content by `Task.format_input`. The
`repo` and `document` inputs of `help_list_repo_documents` and
`help_get_repo_document` are therefore declared with `nofile: true`: without
it, `document: 'README.md'` (or any other name that happens to exist in the
cwd) would silently be replaced by the content of that file instead of being
used as a literal identifier.

## Known limitations

- Identifiers can collide when a source has multiple `doc*` directories (for
  example `doc/` and `docs/` holding the same relative paths): the identifier
  map is built by assignment, so the last file produced by the glob wins.
- The direct-path fallback `root[document]` used for `research/` and `doc/`
  prefixed documents is not sanitized against `..`, so a crafted document name
  can address files outside the resolved source root.
- `help_overview` still only aggregates the `REPOS` list; workflow
  documentation sources are not part of the generated guide.
- The listing only picks up markdown files (`.md`) under `doc*/` and
  `research/`; other formats are invisible to these tasks.

## Notes for agents

- `help_list_repo_documents` and `help_get_repo_document` raise controlled
  `ParameterException` errors on unknown sources or missing documents; treat
  those as normal misses, not crashes. The miss message of
  `help_get_repo_document` includes up to 10 available identifiers.
- Use `help_list_repos` for repository names and `help_list_workflows` for
  workflow names before guessing a `repo` argument; both are cheap, purely
  local discovery steps.
- Workflow documentation follows the standard Scout README format: an
  introductory description, then a `# Tasks` section whose `## <task name>`
  subsections describe each task. Keep that structure when editing any
  workflow's README.
- Avoid calling `help_overview` in automated checks; use the deterministic
  listing and retrieval tasks instead.
