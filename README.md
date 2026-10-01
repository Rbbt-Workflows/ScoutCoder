Documentation to help coding agents writing Scout code

ScoutCoder is an AI-assisted Scout workflow for retrieving framework documentation, exploring project files, and coordinating multi-agent development work over a local codebase. The documentation lookup also covers any installed Scout workflow, since workflows can carry their own README.md, doc*/ and research/ folders in the same format as Scout repositories.

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
  document: 'user/Cookbook.md'
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

When developing code in ruby using the Scout/Rbbt framework, if you struggle
with some detail that you had to figure out but could be better explained in
the documentation, please make a note so can be revised at a later time to
improve the documentation. The format for these notes is a ruby comment, of
possibly multiple lines, starting with the tag 'ScoutCoder:', followed by
a statement that describes what you had to learn to write the good version. As
in this example:

```ruby

# ScoutCoder: when using TSV.traverse you can tell it to save the result into :stream,
# with returns an IO inmediately and write into the write end in parallel

io = TSV.traverser tsv, into: :stream do |key,value|
    values.first
end

Open.consume_stream io

```

## Testing

ScoutCoder-authored task tests can be created with `author_task_test` and run
with `run_task_test`. For a task authored at `share/tasks/<task_name>.rb`, the
paired test is stored at `share/test/task/<task_name>.rb`. Authoring requires
an existing task source under `share/tasks`, validates the name and Ruby
syntax, and refuses to overwrite an existing test. The runner starts a fresh
Ruby process, loads the current `workflow.rb` (including the task files it
discovers), runs that test, and returns its exit status and captured output.
It has a configurable positive timeout (default 120 seconds). Tests that
execute Scout jobs should clean the addressed jobs themselves when freshness
matters; a fresh Ruby process does not imply an empty persistent Scout job
cache. Test source is trusted Ruby code and is not OS-sandboxed by this runner.

For example, run one existing authored test from Ruby with:

```ruby
ScoutCoder.job(:run_task_test, nil, task_name: 'my_task').run
```

To create a test first, pass its Ruby source to `author_task_test`:

```ruby
ScoutCoder.job(:author_task_test, nil,
  task_name: 'my_task',
  test_source: "require 'test/unit'\nclass MyTaskTest < Test::Unit::TestCase\n  def test_example; assert_equal 2, 1 + 1; end\nend\n"
).run
```

These helpers address task source at `share/tasks/<task_name>.rb` and test
source at `share/test/task/<task_name>.rb` in this checkout.

When developing a Scout workflow, use ScoutCoder's workflow-development
tools to discover tasks, inspect their inputs, source and declared
dependencies, run a task, and inspect or monitor the resulting job. The
normal authoring loop is `define_task` to create
`share/tasks/<task_name>.rb`, `author_task_test` to add its paired test, and
`run_task_test` to execute that test in a fresh Ruby process; `run_task` is
kept for debugging a task interactively once the loop is green.

While a task lives under `share/tasks`, its documentation is its `desc`
declaration. When the task is promoted into `lib/ScoutCoder/tasks`, the
`desc` is removed and the documentation is written into this README's `# Tasks`
section with `document_task`; a promoted task must not keep both.
`define_task` validates the declaration and Ruby syntax but does not load the
candidate, confirm task registration, or smoke-test it; the paired-test run
is the load check. `run_task` executes synchronously and reports whether it
replayed a cached result; clean (or otherwise establish freshness) when
validating recent code changes. `job_info` and `job_status` inspect an
addressed job without running the task again. The following tools describe
and operate on tasks in the named workflow.

# Tasks

## task_code
Inspect a task's source location and source-file text

Inputs: `workflow` and `task`. Returns the source path, definition line, and
entire source file when the task's runtime source location identifies a
readable file. The returned text is the whole file, not an extracted task
body. Unavailable source is reported with a reason.

## task_dependencies
Inspect declared static dependencies and dynamic dependency blocks

Inputs: `workflow` and `task`. Reports static dependency declarations
separately from dynamic dependency blocks. A dynamic block's presence does
not enumerate the complete dependency list; the output explicitly marks the
list as incomplete when applicable.

## define_task
Create a new ScoutCoder task source file

Inputs: `task_name` and `definition` (both required) plus optional
`export_type`. The task name must match `[a-z][a-z0-9_]*`; the Ruby source
must declare the matching task. The source is wrapped in `module ScoutCoder`,
syntax-checked, and created as `share/tasks/<task_name>.rb` without
overwriting an existing file. `export_type` accepts `export` or `export_exec`
(the default, so the task appears as an agent tool), or `none` to omit the
export declaration entirely. Invalid values are rejected.

After syntax validation and file creation, `define_task` reloads the active
ScoutCoder workflow in the current Ruby process and verifies that the task is
registered. This loads all discovered `share/tasks/*.rb` files, not only the
candidate. Their Ruby code is trusted and executes in-process; top-level side
effects are possible. If loading fails, the candidate file remains on disk
and workflow state may be partially changed in memory (there is no rollback).
The result reports syntax, load, and registration validation separately.

The development loop is `define_task` -> `author_task_test` ->
`run_task_test` -> `run_task`. The test is run in a fresh Ruby process and is
the validation step; use `run_task` only for interactive debugging after the
test passes. Documentation for a task still under `share/tasks` is supplied
with `desc` in its definition; at promotion time the `desc` is removed and
`document_task` writes the README entry instead.

Example definition text:

```ruby
definition = <<~'RUBY'
  task :greet, :string do |name|
    "Hello, #{name}!"
  end
RUBY

ScoutCoder.job(:define_task,
  task_name: 'greet',
  definition: definition
).run
```


## author_task_test
Create a test for an existing ScoutCoder-authored task

Inputs: `task_name` and `test_source`. The paired test is written following
the task's source location: `share/test/task/<task_name>.rb` for tasks
authored under `share/tasks`, or `test/ScoutCoder/tasks/test_<file>.rb` for
tasks in `lib/ScoutCoder/tasks`. The task name must match
`[a-z][a-z0-9_]*`, and the corresponding task source must exist. The source
is Ruby syntax-checked before writing; an existing test file is never
overwritten. The test is not run during creation. Use `run_task_test` to
execute it. Test source is trusted code and is not OS-sandboxed.

## run_task_test
Run an authored task test in a fresh Ruby process

Inputs: `task_name` and positive `timeout_seconds` (default 120). Loads the
current `workflow.rb` (including every authored task file), then executes the
paired test — `share/test/task/<task_name>.rb` for tasks under `share/tasks`,
or `test/ScoutCoder/tasks/test_<file>.rb` for tasks in `lib/ScoutCoder/tasks`
— with `lib/` on the Ruby load path. Returns pass/fail, exit status, standard
output and standard error, timeout status, and the invocation details. A fresh
Ruby process loads current source and task discovery, but does not clear
persistent Scout job caches; tests should explicitly clean jobs where
freshness matters.

## document_task
Add or replace a task entry in the ScoutCoder README.md Tasks section

Inputs: `task_name` and `documentation`. Replaces the existing
`## <task_name>` entry, or appends a new entry at the end of the `# Tasks`
section. The documentation is Markdown body text placed beneath the generated
heading.

This is the promotion step for task documentation: an authored task carries
its documentation in a `desc` while it lives under `share/tasks`, and when it
is promoted into `lib/ScoutCoder/tasks` the `desc` is removed and the entry is
written here with `document_task`. See the Testing and development notes above
for the promotion loop.

## list_tasks
List tasks declared by a workflow

Inputs: `workflow` (required string). Returns the sorted tasks with each
task's name, description, result type, and directly declared inputs. This is
the discovery step; dependencies are not included in this listing. Use
`task_inputs` to inspect inputs propagated from dependencies as well.

## task_inputs
Inspect direct and recursive inputs for one workflow task

Inputs: `workflow` and `task` (required strings). Returns the task description
and result type, plus `direct_inputs` and `recursive_inputs`. Each input entry
includes its name, type, description, default, and whether it is required.
This inspection does not execute the task.

## run_task
Run a workflow task synchronously

Inputs: `workflow` and `task` (required strings), `inputs` (JSON object as
text, default `{}`), and `clean` (boolean, default `false`). It runs the task
with the supplied inputs and returns compact JSON with the status, output, job
path and short path, whether the result was replayed from cache, and any
captured error. Set `clean: true` to clean the addressed job before running.

For example, inspect and then run a task with its inputs:

```ruby
ScoutCoder.job(:task_inputs, nil,
  workflow: 'ComputerUse',
  task: 'read'
).run

ScoutCoder.job(:run_task,
  workflow: 'ComputerUse',
  task: 'read',
  inputs: '{"path":"README.md"}'
).run
```

`run_task` is the execution tool; use `job_info` or `job_status` when you
already have the workflow, task, and inputs for an existing job and only need
to inspect it.

## job_info
Inspect the recorded information for a workflow job

Inputs: `workflow` and `task` (required strings), and `inputs` (JSON object as
text, default `{}`). Resolves the job from those values and reports its job path and short path,
status, timestamps, messages, and exception metadata when available. It does not run the task.

## job_status
Inspect the current status of a workflow job

Inputs: `workflow` and `task` (required strings), and `inputs` (JSON object as
text, default `{}`). Resolves the job from those values and reports its
status, whether it is running, timestamps, and exception metadata when
available. It does not run the task.

## help_list_repos
List the Scout documentation repositories known to ScoutCoder

This task returns the fixed list of Scout repository checkouts under `~/git` used by the rest of the documentation helpers. At the time of writing it includes `scout-gear`, `scout-essentials`, `scout-camp`, `scout-ai`, and `scout-rig`.

Use this task as the discovery step when an agent knows it needs framework documentation but does not yet know where that documentation lives. The returned values are valid inputs for `help_list_repo_documents` and `help_get_repo_document`.

Note that this list only contains the Scout repository checkouts under `~/git`. Installed workflow names are an additional kind of documentation source, and they are listed by `help_list_workflows` instead.

## help_list_repo_documents
List the documentation files available in one Scout repository or workflow

The `repo` input is a required free string (a `:string` input declared with `nofile: true`) naming either one of the known Scout repositories under `~/git` or any installed Scout workflow (see `help_list_workflows`). The task returns the identifiers of the documentation files of that source, not their contents.

The listing covers the source's `README.md` plus all markdown files under its `doc*/` subtrees plus the markdown files under its `research/`. Identifiers are relative to their containing `doc*` directory (for example `doc/user/Cookbook.md` is listed as `user/Cookbook.md`), `README.md` keeps its literal name, and research files carry a `research/` prefix.

Names that are neither a `~/git` checkout nor a resolvable installed workflow raise a controlled `ParameterException` ("Unknown repo or workflow: <name>"). This is the normal follow-up to `help_list_repos` or `help_list_workflows`: agents inspect the available document identifiers first and then request the specific files that match the concepts they need.

## help_get_repo_document
Return the contents of a documentation file from one Scout repository or workflow

The `repo` input has the same semantics as in `help_list_repo_documents`: a required free string (declared with `nofile: true`) naming a Scout repository under `~/git` or any installed Scout workflow. The `document` input (also `nofile: true`) is one of the identifiers produced by `help_list_repo_documents`.

The task resolves the document through a fallback chain: the literal `README.md` of the source, an exact identifier match from the listing, a `doc*/**/<document>` glob, a direct `research/` or `doc/` path, and finally a `research/**/<document>` glob. The full text of the first match is returned.

If no step of the chain matches, the task raises a `ParameterException` whose message lists up to 10 available documents, which makes failures explicit and easy for an agent to recover from.

This is the lowest-level documentation lookup task. Use it when an agent already knows the exact document it needs and wants the raw markdown to read or quote.

## help_overview
Generate a guide to the available Scout framework documentation

This task builds a synthetic overview by reading all documentation files from the known Scout repositories and asking an agent to produce a markdown guide for other agents. The result is not a static hand-written file; it is generated from the currently available documentation and can evolve as the source repositories evolve.

In practice this is a good first stop when an agent has a broad question such as where to learn about workflows, entities, TSV processing, command execution, or LLM integration. The answer should help narrow the search before calling `help_get_repo_document` on specific files.

## help_workflow
Return the markdown documentation for a workflow

The `workflow` input names any workflow that can be loaded through `Workflow.require_workflow`. The task then calls `documentation_markdown` on that workflow and returns the result as markdown text.

This is useful both for introspection and for tool discovery. For example, an agent can read the documentation for `ScoutCoder` itself, inspect the inherited `ComputerUse` workflow, or query the docs of another installed workflow before interacting with it.

## help_list_workflows
List the workflows installed and available to ScoutCoder

This task unions `Workflow.installed_workflows`, a purely local scan of the `workflows` pathmap that never triggers network autoinstall, with the workflow modules already loaded in the current process. The combined list is deduplicated and sorted.

It is the discovery step for workflow names: any name it returns is usable as the `repo` input of `help_list_repo_documents` and `help_get_repo_document`, which then read the workflow's own `README.md`, `doc*/`, and `research/` documentation.
