ScoutCoder: coding agent for the Scout stack — documentation discovery and workflow development with its own task surface

ScoutCoder is an AI-assisted Scout workflow for retrieving framework
documentation and developing Scout workflows over a local repository
checkout, with 16 registered tasks of its own, all of them agent-exposed
through `LLM.workflow_tools`. The workflow being developed
or explored is the one defined by the `workflow.rb` file in the current
process directory (`PWD`), treated as the repository root; ScoutCoder
supplies the general-purpose workflow-development tools, while the target
workflow provides its own domain-specific tools.

Its capabilities fall into two groups:

1. **Documentation and framework discovery** — retrieve documentation
   across the Scout ecosystem and installed workflows, and explore their
   available functionality (`help_list_repos`, `help_list_workflows`,
   `help_list_repo_documents`, `help_get_repo_document`, `help_overview`,
   `help_workflow`).
2. **Workflow development and inspection** — author tasks, entities and
   entity properties as drafts through the agent path kinds (`task`,
   `entity`, `entity_property`, `python_task`, `test_file`, `probe`);
   validate them (`path_validate`, `path_smoke`), run their tests and
   probes in fresh processes through the single `path_run` operation
   (`kind: "test_file"` for test files, `kind: "probe"` for probes);
   debug tasks from installed workflows (`debug_task`); and
   inspect or document the resulting jobs (`job_info`, `job_status`,
   `document_task`, `reload_workflow`, `list_tasks`, `task_inputs`,
   `task_dependencies`, `task_code`, `list_entities`).

Quick start:

```ruby
require './workflow'

repos    = ScoutCoder.job(:help_list_repos).run
docs     = ScoutCoder.job(:help_list_repo_documents, nil, repo: 'scout-gear').run
text     = ScoutCoder.job(:help_get_repo_document, nil, repo: 'scout-gear',
                         document: 'user/Cookbook.md').run
entities = ScoutCoder.job(:list_entities).run
```

Usage detail for agents:

- Choosing the right tool, layered validation, fresh process vs fresh
  result, change and promotion doctrine:
  [Tool selection](doc/user/ToolSelection.md).
- Authoring entities, properties and Python tasks:
  [Authoring entities](doc/user/AuthoringEntities.md).
- The six path kinds — virtual paths, validate, smoke, paired tests,
  `path_run` (tests and probes), promote, wiring after promotion:
  [Path kinds guide](doc/user/PathKinds.md).
- Testing and execution — choosing a runner, running a task directly:
  [Testing](doc/user/Testing.md).
- The documentation lookup loop and the `ScoutCoder:` comment convention:
  [Documentation](doc/user/Documentation.md).
- Entry point with examples: [doc/user/README.md](doc/user/README.md).

Developer material — repository layout, LiveWorkflow and reload semantics,
property dispatch internals, path-kind registration and capability matrix,
testing internals: [doc/developer/README.md](doc/developer/README.md).

Skills for coherent capabilities live under `skills/`:
`scoutcoder-help-discovery` (when to look up Scout documentation vs ask
ScoutCoder), `scoutcoder-entity-authoring` (authoring
entities/properties/Python tasks), `scoutcoder-path-kinds-lifecycle`
(operational author→validate→test→probe→promote loop),
`scoutcoder-repo-documentation` (writing and reviewing README, `doc/`
and `research/` material, agent-facing overrides and skills folders).

## Running tests and probes: `path_run`

`path_run` is the single agent operation that executes the two runnable
path kinds, each in a fresh process that preloads the owning checkout's
`workflow.rb`:

- `kind: "test_file"` runs Scout test files — one file (`scope: "file"`),
  every file under a path prefix (`scope: "directory"`) or the whole suite
  (`scope: "suite"`), with per-file exit classification and counts.
- `kind: "probe"` runs one probe Ruby snippet unsandboxed with the
  caller's authority; with `source` it writes, syntax-checks and executes
  the probe in one call (create-and-run), and without `source` it
  re-executes the saved probe.

`source` applies only to `kind: "probe"` and `scope` only to
`kind: "test_file"`; an option that does not apply to the addressed kind
is rejected before anything executes. `timeout_seconds` is optional
(1..3600; the runner's own default applies when omitted). `path_run` is
an agent path-kind operation, not a registered workflow task — its `kind`
enum lists exactly the runnable kinds registered for the agent. One-line
example (the full set of copyable examples lives in the
[Path kinds guide](doc/user/PathKinds.md) § `path_run`):

```
path_run(kind: "probe", path: "hello_probe", source: "puts 'hello'")
```

Both kinds execute trusted code UNSANDBOXED with the caller's authority
(trust statement: [Path kinds guide](doc/user/PathKinds.md)
§ Trust boundaries).

## See also (verified pointers)

- scout-ai `doc/developer/Sandbox.md` § "Is this tool sandboxed?" — which
  tools are confined and how the two permission layers relate.
- scout-ai `doc/developer/PathEngine.md` § "Registering a kind" and
  "Callback contract and trust boundary" — the engine semantics under the
  path kinds.
- scout-gear `doc/user/WorkingWithEntities.md` § "Format and identifier
  translation" — entity identifier-file conventions.
- scout-gear `doc/developer/EntitySystem.md` § "Entity definition" and
  "Property dispatch" — the entity/property machinery the entity path
  kinds' validators check against.
- scout-gear `doc/user/CachingData.md` § "Where persistence lives
  (ecosystem split)" — where job/Step results actually persist.
- Workspace `doc/user/TSV.md` — TSV task semantics in the Workspace
  workflow (local doc).

# Tasks

## list_entities
List all known entity modules and metadata

Takes no inputs. Returns one sorted record per entity module that has
extended `Entity` in the current process (deduplicated; framework modules
included), covering annotations, formats, identifier files, properties,
inferred source paths, effective dispatch and persistence status — with the
inference limits (source-path and dispatch-alias) documented in
[Authoring entities](doc/user/AuthoringEntities.md).

## task_code
Inspect a task's source location and source-file text

Inputs: `workflow` and `task`. Returns the source path, definition line and
entire source file (the whole file, not an extracted body) when the task's
runtime source location identifies a readable file; unavailable source is
reported with a reason.

## task_dependencies
Inspect declared static dependencies and dynamic dependency blocks

Inputs: `workflow` and `task`. Reports static dependency declarations
separately from dynamic dependency blocks; a dynamic block's presence does
not enumerate the full dependency list, and the output marks the list as
incomplete when applicable.

## document_task
Add or replace a task entry in the <workflow> README.md Tasks section

Inputs: `task_name` and `documentation`. Replaces the existing
`## <task_name>` entry or appends a new one at the end of the `# Tasks`
section, placing the Markdown body beneath the generated heading. This is the
documentation half of promotion: a draft task carries its docs in a `desc`
under `share/tasks`, and once promoted into `lib/<workflow>/tasks` the `desc`
is dropped and the entry is written here. Promotion loop:
[Testing](doc/user/Testing.md) § "Documentation during promotion".

## list_tasks
List tasks declared by a workflow

Inputs: `workflow` (required string). Returns the sorted tasks with each
one's name, description, result type, directly declared inputs, source
location and a dependency summary (static declarations plus whether a
dynamic block is present, without expanding it). Use `task_inputs` for
dependency-propagated inputs and `task_dependencies` for the detail.

## task_inputs
Inspect direct and recursive inputs for one workflow task

Inputs: `workflow` and `task` (required strings). Returns the task
description and result type, plus `direct_inputs` and `recursive_inputs`
(each entry: name, type, description, default, required); the task is not
executed. Note that recursive inputs are exactly what agent-exposed workflow
tools present (the tool schema is built from `rec_inputs(name).uniq`), and
re-declaring a dependency input on the parent is free. Propagation detail:
scout-gear `doc/user/BuildingWorkflows.md` § dependencies.

## debug_task
Run a workflow task synchronously and return execution information

Inputs: `workflow` and `task` (required strings), `inputs` (JSON object as
text, default `{}`), and `clean` (boolean, default `false`). Runs the task
through ordinary Scout job execution and returns compact JSON with status,
output, job path, replay status and any captured error; `clean: true`
recomputes the addressed job. It is a task-execution surface, not a test
runner or an OS sandbox. Inspect-then-run examples and where job outputs
land: [Testing](doc/user/Testing.md) § "Running a task directly".

This is not the normal way for agents to run a task; instead, it should be
provided as part of their tooling as regular tool calling functions.

`debug_task` is the execution tool; use `job_info` or `job_status` when you
already have the workflow, task, and inputs for an existing job and only need
to inspect it.

## job_info
Inspect the recorded information for a workflow job

Inputs: `workflow` and `task` (required strings), and `inputs` (JSON object
as text, default `{}`). Resolves the job from those values and reports its
job path and short path, info file, status, timestamps, messages, and
exception metadata when available; it does not run the task.

## job_status
Inspect the current status of a workflow job

Inputs: `workflow` and `task` (required strings), and `inputs` (JSON object
as text, default `{}`). Resolves the job from those values and reports its
status, whether it is running, timestamps, and exception metadata when
available; it does not run the task.

## help_list_repos
List the Scout documentation repositories known to ScoutCoder

Returns the fixed list of Scout repository checkouts used by the documentation helpers (`scout-essentials`, `scout-gear`, `scout-camp`, `scout-rig`, `scout-ai`; code order in [Layout](doc/developer/Layout.md)). Use it as the first discovery step when framework documentation is needed but its location is unknown; the values feed `help_list_repo_documents` and `help_get_repo_document`. Installed workflow names are a separate documentation source, listed by `help_list_workflows`.

## help_list_repo_documents
List the documentation files available in one Scout repository or workflow

Input: `repo`, a required free string naming either one of the known Scout repositories or any installed Scout workflow (see `help_list_workflows`). Returns the identifiers — not the contents — of that source's documentation: `README.md` plus all markdown under its `doc*/` subtrees and `research/` (identifiers relative to their `doc*` directory, `README.md` literal, research prefixed). Resolution follows the documented chain (path map → `~/git/<name>` → workflow load → gem; unknown names raise a controlled `ParameterException`), and colliding identifiers across several `doc*` trees resolve to the last file from the glob. Use it after `help_list_repos`/`help_list_workflows` to pick exact documents before fetching.

## help_get_repo_document
Return the contents of a documentation file from one Scout repository or workflow

Inputs: `repo` (same semantics as `help_list_repo_documents`) and `document` (one of that task's identifiers). Returns the full text of the first match in the documented fallback chain (literal `README.md` → exact identifier → `doc*/**/<document>` glob → direct `research/`/`doc/` path → `research/**/<document>` glob). A miss raises a `ParameterException` listing up to 10 available documents — treat it as a normal miss, not a crash. The lowest-level lookup, for when the exact document is already known.

## help_overview
Generate a guide to the available Scout framework documentation

Takes no inputs. Builds a synthetic, model-generated guide to the fixed Scout repository set (not installed workflows) by reading their documentation and issuing one LLM call; the result evolves with the sources and is not a static file. Relatively expensive: prefer the deterministic lookups (`help_list_repos` → `help_list_repo_documents` → `help_get_repo_document`) and use this only when they cannot localize a broad topic (where to learn workflows, entities, TSV, command execution, LLM integration). Requires the Scout-AI agent machinery in the calling context; a plain workflow process without it fails early.

## help_workflow
Return the markdown documentation for a workflow

Input: `workflow`, any name loadable through `Workflow.require_workflow`. Loads it with network autoinstall disabled (it must already be available locally) and returns its `documentation_markdown` — the `workflow.md` or `README.md` beside the workflow `libdir`. Useful for introspection and tool discovery before interacting with another workflow.

## help_list_workflows
List the workflows installed and available to ScoutCoder

Takes no inputs. Unions `Workflow.installed_workflows` (a purely local scan of the `workflows` pathmap, never triggering network autoinstall) with the workflow modules already loaded in the process, deduplicated and sorted; the local scan is wrapped so the task never crashes. The discovery step for workflow names: every returned name is usable as the `repo` input of the documentation lookup tasks.

## reload_workflow
Reloads a workflow in the current execution process.

Reload a workflow to make newly created or modified tasks, entities, and properties available in the current execution process.

After promoting Ruby tasks, entities, or properties, finish wiring the project loader and reload the checkout containing the edited `workflow.rb`. A single promotion's automatic reload precedes any subsequent wiring edits. Related promotions can use `defer_reload: true` and share one post-wiring reload.

Pass the absolute checkout directory as `root`. The helper purges cached Ruby features under that root and re-evaluates its entrypoint. It returns `ok`, `root`, `entrypoint`, `purged`, `workflow`, and `reload`.

Delegated agents execute in isolated processes. Changes to workflow source files are shared, but loaded definitions are process-local. Reloading a workflow in a delegated ScoutCoder conversation does not update the requesting agent's runtime. Agents consuming newly developed capabilities should invoke `reload_workflow` themselves.

Reloading makes entity definitions and properties available through Semantics without requiring changes to its tool definitions. Newly exported tasks, however, become callable tools only when the agent's tooling is reconstructed. Subsequent delegations inherit the updated runtime and can discover the new tasks when their tooling is prepared, provided the workflow is exposed to them.

Reloading does not invalidate persisted computational results. Use the appropriate job refresh mechanism when results need to be recomputed.

[Exact arguments, receipt fields and consumer checks](doc/user/PathKinds.md#force-the-reload-and-verify-consumer-access)
