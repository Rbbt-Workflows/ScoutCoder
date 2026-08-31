# Workflow Documentation Sources: Design Note

Note: the design described in this note is now implemented in `lib/ScoutCoder/tasks/documentation.rb`, with one difference: discovery of workflow sources is a separate `help_list_workflows` task, while `help_list_repos` remains repository-only.

## Why this note exists

The ScoutCoder help tasks (`help_list_repos`, `help_list_repo_documents`,
`help_get_repo_document`, `help_overview`) were built around a hardcoded list
of Scout repositories. In practice, however, a lot of Scout documentation lives
in workflow checkouts, which follow the exact same documentation conventions
as the repos. This note records the analysis behind unifying both kinds of
sources under one resolution mechanism.

## Two kinds of documentation sources

### Scout repos

Ruby gems / git checkouts such as `scout-gear`, `scout-essentials`,
`scout-camp`, `scout-ai`, and `scout-rig`. They are conventionally checked out
under `~/git/<name>`, and their documentation tree is:

- `README.md` at the repo root,
- `doc/` (plus any other `doc*`-prefixed directory) with nested markdown,
- `research/` with design and analysis notes.

`help_list_repo_documents` currently globs only `doc*/**/*.md` and never
includes `README.md` or `research/`.

### Scout workflows

Workflow checkouts such as `ComputerUse` or `ScoutCoder`. A workflow is a
`Workflow` module with a `workflow.rb` and a `lib/<WorkflowName>/` tree; it is
loaded through `Workflow.require_workflow <name>`, which leaves the module
carrying a `libdir` pointing at `lib`. From `libdir` the checkout root is
reachable, so the same documentation layout (`README.md`, `doc*/`, `research/`)
applies.

Crucially, workflow documentation uses the same README format as Scout repos:

1. A one-line title.
2. One or more description paragraphs (header markers allowed).
3. A `# Tasks` section, followed by one `## <task name>` subsection per task:
   task name, a one-line description, then explanatory paragraphs.

`Workflow#documentation`/`documentation_markdown` already parse this format,
and `help_workflow` already serves it for any installed workflow. So a
workflow checkout is a fully valid documentation source; nothing about the
format needs to change.

## Unification plan

1. **Source resolution**: given a source name, resolve a documentation root:
   1. If `~/git/<name>` exists, that directory is the root (repo case).
   2. Otherwise, attempt `Workflow.require_workflow <name>` (with
      `SCOUT_WORKFLOW_AUTOINSTALL=false`) and take the workflow's `libdir`,
      from which the checkout root is derived (workflow case).
   3. Only if both fail should the caller get a controlled error.
2. **Listing**: enumerate documentation under a resolved root as
   `README.md`, plus `doc*/**/*.md`, plus `research/**/*.md`. This makes
   repo and workflow sources indistinguishable from the caller's point of
   view.
3. **Retrieval**: `help_get_repo_document` should accept any identifier
   produced by the listing task, resolving it against the same root; unknown
   identifiers still raise `ParameterException`.
4. **Discovery**: `help_list_repos` should expose both the known repos and the
   installed workflows (from `Workflow.workflows` / the workflow directory),
   rather than a single hardcoded `REPOS` array.

## Requirements for the listing change

Any listing implementation must cover, for each resolved source:

- `README.md` (always present in a standard source),
- every markdown file under `doc/` and any other `doc*` directory,
- every markdown file under `research/`.

A glob restricted to `doc*/**/*.md` is therefore insufficient: it silently
drops `research/` notes and the README itself, which are often the most useful
documents for an agent trying to understand a codebase.

## Caveats

- `Workflow.require_workflow` may attempt network autoinstallation unless
  `SCOUT_WORKFLOW_AUTOINSTALL=false` is forced (as `help_workflow` already
  does). The unified resolution must keep that guard.
- Workflow names differ from repo names in case convention (camelCase vs
  kebab-case); resolution should try the literal name first, as
  `locate_workflow_file` already does for workflow files.
- `help_overview` concatenates all documentation into one LLM call; extending
  the source list also grows that call, so it should keep being excluded from
  cheap regression checks.
