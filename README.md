Documentation to help coding agents writing Scout code

ScoutCoder is an AI-assisted Scout workflow for retrieving framework documentation and developing Scout workflows over a local repository checkout. It provides tools to explore installed workflows and author, inspect, and test workflow tasks, helpers, and entity definitions.

ScoutCoder's documentation lookup covers both the core Scout ecosystem and any installed Scout workflow. In addition to local clones of the `scout-gear`, `scout-essentials`, `scout-camp`, `scout-ai`, and `scout-rig` repositories under `~/git`, it indexes the documentation available in installed workflows, including their `README.md`, `doc*/`, and `research/` directories, which follow the same conventions as Scout repositories.

**ScoutCoder separates workflow-development tools from domain-specific tools.** The workflow being developed or explored is the one defined by the `workflow.rb` file in the current process directory (`PWD`). This directory is treated as the repository root, with the workflow representing that project. ScoutCoder supplies the general-purpose workflow-development tools, while the target workflow provides its own domain-specific tools.

Its capabilities fall into two main groups:

1. **Documentation and framework discovery:** Retrieve documentation across the Scout ecosystem and installed workflows, and explore their available functionality.
2. **Workflow development and inspection:** Author tasks, helpers, and entity definitions; create and run their tests in fresh processes; execute tasks from installed workflows; and inspect or document the resulting jobs.

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

entities = ScoutCoder.job(:list_entities).run

listing = ScoutCoder.job(:list_tasks, nil,
  workflow: 'ScoutCoder'
).run
```

```bash
scout workflow task ScoutCoder help_list_repos
scout workflow task ScoutCoder help_workflow \
  --workflow ScoutCoder
```

The documentation tasks are most useful when an agent needs Scout-specific
context before touching code. The authoring and inspection tasks are the
normal working loop for developing or auditing workflow code.

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

## See also (verified pointers)

- scout-ai `doc/developer/Sandbox.md` § "Is this tool sandboxed?" — which tools are confined and how the two permission layers relate.
- scout-ai `doc/developer/PathEngine.md` § "Registering a kind" and "Callback contract and trust boundary" — the engine semantics under [Agent path kinds](#agent-path-kinds).
- scout-gear `doc/user/WorkingWithEntities.md` § "Format and identifier translation" — entity identifier-file conventions.
- scout-gear `doc/developer/EntitySystem.md` § "Entity definition" and "Property dispatch" — the entity/property machinery the authoring tools wrap.
- scout-gear `doc/user/CachingData.md` § "Where persistence lives (ecosystem split)" — where job/Step results actually persist.
- scout-rig `doc/user/DefiningPythonTasks.md` — the Python task authoring contract behind `define_python_task`.
- Workspace `doc/user/TSV.md` — TSV task semantics in the Workspace workflow (local doc).

## Contents

- [Development doctrine and tool selection](#development-doctrine-and-tool-selection) — tool table, layered validation, execution vs file authorization, fresh process vs fresh result, promotion.
- [Layout conventions](#layout-conventions) and [LiveWorkflow](#liveworkflow) — directory layout and the `share/` draft-loading contract.
- [Authoring ScoutCoder entities](#authoring-scoutcoder-entities) — entity, property and Python task authoring formats.
- [Agent path kinds](#agent-path-kinds) — kinds and roots, [two locations](#the-two-locations), [validate](#validate), [test_file run_test](#test_file-run_test), [promote](#promote), [wiring after promotion](#wiring-after-promotion-read-this-before-promoting), [trust boundaries](#trust-boundaries), [when to use which](#when-to-use-which).
- [Testing and execution](#testing-and-execution) — choosing a runner, [authoring and running tests](#authoring-and-running-tests), where job outputs land, [running a task directly](#running-a-task-directly), [documentation during promotion](#documentation-during-promotion).
- [# Tasks](#tasks) — per-task reference entries: authoring generators, test runners, job inspection, documentation lookup.

## Development doctrine and tool selection

Use the tool whose responsibility matches the work. ScoutCoder provides Scout-aware discovery and authoring; the Path Engine provides authorized operations on registered virtual resources; Workspace is for general repository edits; task and test runners execute code through the ordinary workflow/process environment.

| Need | Preferred tool | Boundary |
|---|---|---|
| Understand existing workflow behavior | `help_workflow`, `list_tasks`, `task_inputs`, `task_dependencies`, `task_code`, `list_entities` | Inspection; no behavior should be inferred from a task name alone |
| Create a workflow task draft | `define_task` | Writes under `share/tasks/`, reloads the workflow, and verifies registration; the trusted draft may execute while loading |
| Manage a registered virtual source/test file | `path_kinds`, then `path_read`, `path_write`, `path_edit`, `path_list`, `path_validate`, `path_smoke`, `path_promote` as supported by the kind | Path authorization covers the addressed resource and configured roots |
| Run a test file | `run_test` for the `test_file` kind; `run_task_test` or `run_helper_test` for their supported conventions | Execution occurs in a fresh process, but `run_test` is deliberately unsandboxed |
| Exercise a workflow task directly | `run_task` | Uses ordinary Scout job execution; check cache replay and clean the addressed job when needed |
| Edit existing source, wiring, tests, or docs | Workspace | The path tools address ONLY the four registered kinds; for any other file — wiring, docs, data, config — use Workspace. Inspect the exact diff and retest; do not assume Workspace and workflow tools share an execution sandbox |

### Validation is layered

- `path_validate` is a static shape/syntax check. It does not run the target.
- `path_smoke` is available on source kinds only. It proves that a task job can be constructed with placeholders for required inputs, that an entity loads/registers, or that an entity-property accessor resolves. It does not execute a task or dispatch a property.
- `run_test` executes assertions in an existing test file. Prefer a behavior-focused test over a smoke check when a behavior claim is being made.
- `run_task` is for invoking a workflow task itself, often as an interactive behavior probe. It does not provide assertions or act as a test suite runner.

### Execution is not the same as file authorization

Path Engine authorization is not a process sandbox, and `run_test` intentionally executes trusted test code unsandboxed; the canonical statement is [Trust boundaries](#trust-boundaries) under [Agent path kinds](#agent-path-kinds), with engine-level semantics in scout-ai `doc/developer/Sandbox.md` § "1. Is this tool sandboxed?" and `doc/developer/PathEngine.md` § "8. Callback contract and trust boundary".

Using `run_task` or `run_test` can avoid the wrong failure mode when a test is being attempted through file-oriented Path Engine operations: execute behavior through the workflow/test runner rather than pretending that a file operation is an execution environment. This is a choice of the proper tool boundary, **not a way to bypass security controls**. Only run trusted code, pass explicit inputs, and test Path Engine authorization separately.

On the removed legacy `path_test` operation, see [Agent path kinds](#agent-path-kinds); do not depend on it in new work.

### Fresh process versus fresh result

Test runners start a new process, but Scout's persistent job and Step caches outlive it. For a meaningful regression check, establish whether the relevant job was recomputed: use `run_task`'s `clean: true` when appropriate, clean a test's exact job/Step if its result needs refreshing, and inspect the reported replay status. See scout-gear `doc/user/CachingData.md` § "Where persistence lives (ecosystem split)" for where job/Step results actually persist.

### Change and promotion doctrine

Inspect before editing. Make the smallest scoped change and preserve the project's conventions. After writing source, read the file back, validate it, run an appropriate load/registration check, and exercise the relevant behavior. Do not treat file existence or successful registration as proof of correct behavior.

Path-kind promotion moves exactly one resource. It does not wire a task/entity/property into `workflow.rb`, load a promoted file, relocate a paired test, or coordinate a multi-file change. Promote related resources separately and make permanent source/wiring changes explicitly with Workspace. Verify the resulting workflow from a fresh process.

Do not commit, push, or merge unless explicitly asked. Report the actual checks performed and keep unresolved failures or unverified assumptions visible.

## Layout conventions

- `workflow.rb` - workflow entrypoint. It requires the lib task files and
  re-extends the global `::LiveWorkflow` module, which loads authoring
  drafts under `share/` (entity drafts before property drafts). It does not
  load any built-in entity tree: `lib/ScoutCoder/entity/` exists but is
  empty, and `workflow.rb` requires no entity or entity-property files from
  it. When a built-in entity tree is added, load its entity files before
  re-extending `LiveWorkflow` and its property files after it, so every
  entity extend precedes property registration from either source.
- `lib/ScoutCoder/` - shipped functionality: task definitions under
  `lib/ScoutCoder/tasks/`, the built-in entity tree under
  `lib/ScoutCoder/entity/`, and the shared test-support modules
  (`task_test_support.rb`, `helper_test_support.rb`).
- `share/` - the authoring-drafts convention. `share/tasks/`,
  `share/helpers/`, `share/entities/` and `share/entity_properties/` hold
  draft definitions loaded live by Scout-gear's `LiveWorkflow` on every
  workflow reload, in ScoutCoder's own checkout and in any other workflow
  that extends it.
  ScoutCoder's own four draft directories are currently empty, so extending
  is a no-op here today.
- `share/test/` - test-file drafts, including the conventional
  `task/`, `helper/`, `entity/`, `entity_property/` and `integration/`
  tiers. They are never loaded by `LiveWorkflow`. Use `run_test` for the
  general `test_file` lifecycle; `run_task_test` and `run_helper_test`
  remain available for their specialized authoring-task conventions.
- `share/entity/` - identifier TSVs (`<entity>.identifiers.tsv`) generated by
  `define_entity`. Data, not code: they are registered by the generated
  entity definition and never loaded as Ruby.
- `test/` - the unit-test tree for the shipped code, following the Scout
  convention `test/ScoutCoder/...` mirroring `lib/ScoutCoder/...`. Built-in
  task tests live at `test/ScoutCoder/tasks/test_<file>.rb`.
- `research/` - non-authoritative notes shared between agents and
  executions.
- `doc/` - none. This README is the sole documentation file for ScoutCoder.

## LiveWorkflow

`LiveWorkflow` is Scout's workflow extension implemented in scout-gear at
`scout/workflow/live.rb`. A target workflow that extends it gets every `*.rb`
draft under its own `share/` loaded on each (re)evaluation of `workflow.rb`,
so tasks, helpers and entity drafts register without a manual load block. A
target workflow extends `Workflow` and the global `::LiveWorkflow` module; the
Scout-gear implementation is loaded through the project's normal load path.
ScoutCoder's `workflow.rb` re-extends this shared Scout extension.

Load order, on every pass: `share/tasks`, `share/helpers`,
`share/entities`, `share/entity_properties` - top-level files of each
subdirectory before nested ones, lexicographic within a level, so loads are
deterministic. Entity files always precede property files, because a
property file loaded before its entity module has no module to register on
and fails loudly at load time (`Entity.extended` guards `@properties` against
being reset, so re-extension itself is not the failure). That ordering is a
contract, not an
implementation detail. When a built-in entity tree is present,
`workflow.rb` relies on the same rule across sources: lib entity files
load, then `LiveWorkflow` loads share entity and property drafts, then lib
property files load. Thus every entity extend precedes property
registration, whether the entity or property comes from `lib/` or `share/`.

Reload semantics. Re-extending the global `::LiveWorkflow` module fires
`self.extended`. `Workflow.require_workflow(file, update: true)`
re-evaluates `workflow.rb`, so adding or editing a draft file and reloading
the workflow picks up the change without restarting. Files are loaded with
Kernel#load, not require, so they re-execute every time. For the
loaded-but-not-re-evaluated case (a workflow object already in memory), call
`workflow.load_live_files!` explicitly; it is the same implementation as the
extended hook. Re-loading never raises on re-declaration: tasks reassign,
helpers redefine, and re-extending Entity is expected behavior.

Hand-authored task and helper draft files loaded by `LiveWorkflow` must wrap
declarations in the target workflow module (`module MyWorkflow ... end`),
because `Kernel#load` evaluates each file at top level. Entity and property
drafts follow their distinct module/body formats described below. The
`define_task` and `define_helper` generators instead add the enclosing module
to their supplied declarations. `define_entity` and `define_entity_property`
wrap their respective supplied sources in the entity module.

Exclusions and tolerance:

- `share/test` is never loaded, in any shape; task and helper tests run in
  fresh processes instead.
- Only `*.rb` files are selected, so identifier TSVs such as
  `share/entity/<entity>.identifiers.tsv` are never loaded as Ruby.
- Missing or empty share subdirectories, and a missing `share/` itself,
  contribute nothing; extending remains valid with no `libdir`.
- Removing a draft file stops re-registering it, but the task or module it
  defined stays in memory for the process lifetime: Ruby cannot unload
  constants or methods. A fresh process clears it. Reload after removal is
  therefore tolerated (no error), not reverted.

## Authoring ScoutCoder entities

ScoutCoder can create entity modules and their properties in this checkout under
`share/entities/` and `share/entity_properties/`. Use `define_entity` to create a
module and `define_entity_property` to add one property at a time. These are
authoring drafts loaded by Scout-gear's `LiveWorkflow` extension; the shipped
built-in entity tree is separately located under `lib/<workflow>/entity/`.

Entity names and property names must match `[a-z][a-z0-9_]*`; an entity name
such as `sample_entity` maps to the top-level `::SampleEntity` module. The entity
base defaults to `Entity`; choose `EntityWorkflow` explicitly when the module
should also expose workflow behavior. The `definition` inputs are trusted Ruby
source bodies, not complete module files. `define_entity` generates the entity
module and its `extend Entity` (or `extend EntityWorkflow`) line; it also adds
identifier registration when the `identifiers` input is supplied. Do not
include the module, entity constant, or base-extension wrapper in `definition`:
an `extend Entity` or `extend EntityWorkflow` call there is rejected. Select the
base with `base`. These generators supply entity scaffolding; a normal entity
file loaded directly by `LiveWorkflow` must supply its own module and extension
lines. For `define_entity_property`, supply a matching
`property :<property_name> => :<dispatch_type> do |args...| ... end` declaration
and body; the generator wraps that source in the existing entity module. The
tool requires the matching `property` declaration but does not infer its
dispatch type, block arguments, or action. `define_entity` writes
`share/entities/<entity>.rb`; `define_entity_property` writes
`share/entity_properties/<entity>/<property>.rb`.

A complete module listing may be useful for understanding the result, but it
is not valid `definition` input. The conceptual generated form below shows
what `base: 'EntityWorkflow'` and `identifiers:` request; it is not a standalone
source template. The entity body is not a full module to paste into `definition`; the
identifiers call is generated only when TSV content is provided.

```ruby
# Illustrative only: the generator uses a qualified module wrapper,
# and emits add_identifiers only when identifiers are supplied.
module SampleEntity
  extend EntityWorkflow
  add_identifiers Path.setup(File.expand_path('../entity/sample_entity.identifiers.tsv', __dir__))
  annotation :organism, 'Example organism'
end
```

For the generated base and identifier setup, pass the body, selected base,
and TSV contents separately, as shown here. The TSV header fields name its
identifier formats (e.g. `#ID,Name`); conventions: scout-gear
`doc/user/WorkingWithEntities.md` § "Format and identifier translation".

```ruby
entity_definition = "annotation :organism, 'Example organism'"
identifier_tsv = "#ID,Name\nexample,Example\n"

ScoutCoder.job(:define_entity,
  entity_name: 'sample_entity',
  definition: entity_definition,
  base: 'EntityWorkflow',
  identifiers: identifier_tsv
).run

property_definition = <<~'RUBY'
  property :label => :single do |prefix, suffix|
    "#{prefix}#{self}#{suffix}"
  end
RUBY

ScoutCoder.job(:define_entity_property,
  entity_name: 'sample_entity',
  property_name: 'label',
  definition: property_definition
).run
```

`define_entity` writes `share/entities/<entity>.rb`; each call to
`define_entity_property` writes `share/entity_properties/<entity>/<property>.rb`.
Scout-gear's `LiveWorkflow` loader loads entity drafts before recursively
loading property drafts in sorted order (see Layout conventions and
LiveWorkflow for the combined order). The authoring tasks refuse to overwrite
existing entity/property files or an already-registered entity/property. They check
names, Ruby syntax, and the entity/property declaration; they do not prove the
semantics of the Ruby code. Since the supplied source executes during workflow
loading and reload, treat it as trusted code, not sandboxed input. A reload or
registration failure can occur after the candidate file has been written; the
task reports the failure but does not generally roll back that file.

### Entity and Python task authoring formats

The authoring tools generate the scaffolding described in the task entries
below. These examples are generator inputs, not complete files. Hand-authored
files loaded directly by Scout-gear's `LiveWorkflow` must be wrapped in the
target workflow module.

- For `define_entity`, supply only the entity body (for example annotations
  and helper declarations), not a `module` wrapper or `extend Entity` /
  `extend EntityWorkflow` line. Select the base through `base`; the generator
  emits the top-level entity module and base extension. If `identifiers` is
  supplied, pass TSV text separately; the tool writes
  `share/entity/<entity>.identifiers.tsv` and generates a relative-path
  `add_identifiers` call. For `define_entity_property`, supply a matching
  `property :<property_name> => :<dispatch_type> do |args...| ... end`
  declaration and executable body. It wraps the complete source in the existing
  entity module. Example `definition`:

  ```ruby
  property :hello => :single do |prefix, suffix|
    "#{prefix}#{self}#{suffix}"
  end
  ```

- For `define_python_task`, author the function definitions and explicit
  `scout.task(function)` registration; the tool inserts only a missing
  top-level `import scout` (after a module docstring and `__future__` imports
  when present). It supplies no function or task declaration. For example:

  ```python
  import scout

  def greet(name: str = "World") -> str:
      return f"Hello, {name}!"

  scout.task(greet)
  ```

An optional `identifiers` input to `define_entity` is the TSV text to write at
`share/entity/<entity>.identifiers.tsv`. It must be non-empty and have a header
accepted by `TSV.parse_header` naming the identifier formats it maps (for
example, `#ID,Name`; identifier-file conventions are documented once in
scout-gear `doc/user/WorkingWithEntities.md` § "Format and identifier
translation"). The generated
entity definition registers that path with `add_identifiers` at load time.
The path is constructed relative to the entity definition file, so
registration does not depend on the process's current working directory.
Draft authoring tasks write entity modules under `share/entities/` and
property source under `share/entity_properties/`; the built-in
module/property loader for `lib/<workflow>/entity/` is a separate
convention. Supplying identifier text also refuses to overwrite an
existing identifier file.

Use `list_entities` to inspect every entity module known to the process:

```ruby
entities = ScoutCoder.job(:list_entities).run
```

With no inputs the task returns one record per module that has extended
`Entity` in the current process, deduplicated: framework modules such as
`AssociationItem` appear alongside any ScoutCoder entities, because the
default enumeration walks the append-only `Entity::MODULES` registry (a
workflow reload re-extends the same module object, which would otherwise
duplicate rows). Its sorted results include each entity's name, module,
detected base kind, annotations, formats, identifier files, registered
properties, effective dispatch, persistence flags, plus inferred source-path
fields. Source paths are inferred from the conventional
`lib/<workflow>/entity/` layout, not tracked from Ruby's runtime source
locations, so framework modules report no checkout paths. Effective dispatch
is inferred from generated method names, so it cannot distinguish the
original `:single2array` alias from `:single`, or `:array2single` from
`:array`. The underlying helper also accepts an explicit module scope, which
restricts the listing to that module's own entity constants; the task itself
exposes no input for it.

Built-in entity definitions and property files live under
`lib/<workflow>/entity/`; today that tree is empty and no loader reads it.
Identifier TSV files remain under `share/entity/`;
they are resource data registered by the generated entity definition. The
`define_entity` and `define_entity_property` authoring tools instead create
drafts loaded by Scout-gear's `LiveWorkflow` under `share/entities/` and
`share/entity_properties/`.
These are separate loading conventions; do not relocate drafts to the built-in
tree expecting the authoring-task loader to discover them.

## Agent path kinds

ScoutCoder registers four path kinds on the scout-ai agent path engine:
`task` (Scout workflow task files), `entity` (Scout entity module files,
one file per entity), `entity_property` (entity property files,
addressed through nested `<entity>/<property>` virtual paths) and
`test_file` (unit and integration test files, addressed through tier
paths such as `task/greet_user` or `integration/round_trip`). They
expose the authoring surfaces of the current project's own workflow
(ScoutCoder's own definitions live in `lib/ScoutCoder/path_kinds.rb`;
the kinds are defined by the workflow of the current directory) as virtual
filesystems an agent operates
with the generic `path_*` tools: the `path_kinds` listing tool plus one
tool per operation — `path_read`, `path_write`, `path_edit`, `path_list`,
`path_move`, `path_rename`, `path_delete`, `path_validate`,
`path_smoke` and `path_promote` — with no per-kind tool fan-out, plus
the `test_file`-kind `run_test` custom operation (one extra installed
tool). ScoutCoder does not register a `test` capability or handler;
explicit test execution is provided by `run_test`.
`path_patch` is not offered for any kind. The kinds travel
only with the whole-workflow `tool: ScoutCoder` introduction: a task-level
tool line registers no kinds.

**Canonical note on the removed legacy `path_test`.** The Scout-AI
engine's older built-in `test` operation conflated test creation and
execution with source-kind operations and obscured the
execution-versus-authorization distinction. It is slated for removal, but
its removal patch may still be unapplied in the engine checkout: if a
legacy `path_test` tool remains visible, do not use or depend on it, and
do not register a kind-level `test` handler. ScoutCoder's supported
design manages test files as `test_file` resources and executes them
explicitly through `run_test`.

Engine-level semantics — registering a kind, declaring kinds from a
workflow's `PATH_KINDS` constant, capability normalization, the callback
contract and the trust boundary — are documented in scout-ai
`doc/developer/PathEngine.md` § "3. Registering a kind" and "8. Callback
contract and trust boundary". This section covers what is specific to
these four kinds.

The paths are always relative to the :current path map, which is the process
working directory (ENV['PWD']). In Scout you should always run inferences from
the base directory of the repository you want to work on, which should contain
at least a 'workflow.rb' file which is the entry point to load that workflow.
The name of that workflow should be the one you use when creating tasks or
helpers.

The project directories were the files get saved should not be included in the
path engine tools as should not be the file extension either. You have been
told about them exclusively so you can find them with the Workspace
tools, but you should forget about them when using the path engine.

### The two locations

Each kind has two locations: `tmp` (default) and `project`. For the three
source kinds (`task`, `entity`, `entity_property`), `tmp` holds source drafts
that LiveWorkflow loads; for `test_file`, it holds test resources that are
never loaded automatically. `path_promote` MOVES one resource from `tmp` to
`project`, where promoted source files are not loaded automatically (see
`Wiring after promotion` below). Roots follow the current project — relative
Scout-path declarations are pinned to it once at registration, and every
operation authorizes against the pinned roots — and are declared per kind:

| kind | tmp root (drafts, default) | project root (promoted) | virtual path |
|---|---|---|---|
| `task` | `share/tasks` | `lib/<workflow>/tasks` | `greet_user` |
| `entity` | `share/entities` | `lib/<workflow>/entity` | `demo_widget` |
| `entity_property` | `share/entity_properties` | `lib/<workflow>/entity` | `demo_widget/tag_palette` |
| `test_file` | `share/test` | `test/<workflow>` | `task/greet_user` |

Concrete physical locations for the example names: a task draft lives at
`share/tasks/greet_user.rb` and, after promotion, at
`lib/<workflow>/tasks/greet_user.rb`; an entity draft at
`share/entities/demo_widget.rb` and, after promotion, at
`lib/<workflow>/entity/demo_widget.rb`; a property draft at
`share/entity_properties/demo_widget/tag_palette.rb` and, after promotion,
at `lib/<workflow>/entity/demo_widget/tag_palette.rb`. Path Engine virtual
paths omit the physical root and the `.rb` suffix.

`entity` and `entity_property` deliberately share the project root:
promoted entity files are flat `<entity>.rb` and promoted property files
are nested `<entity>/<property>.rb` below it. The `entity_property`
virtual path is nested for the same reason — one declarative promotion
destination covers the whole kind. A flat property path (`tag_palette.rb`)
is a validate error, not a second supported shape.

`test_file` is the odd one out: it manages TEST files, not source
drafts, and its roots cover unit and integration tests on both sides.
The virtual path's FIRST segment is the tier — `task`, `entity`,
`entity_property`, `helper`, or the marker `integration` — and unit vs
integration is decided purely by that first segment (`integration/...`
is an integration test; everything else is a unit test). The complete
tier-spelling rules (which side carries the `test_` prefix, which
directories are renamed, the open-tier rule, and the resolved
inverse-mapping guarantee) are stated ONCE below with the advisory
pairing map in [validate](#validate).

**Unit-test path convention is doctrine, not enforcement.** Mirroring the
tested file's path under the test tree is enforced only through this
documentation and advisory checks — nothing hard-rejects a test that
lives elsewhere inside the test tree. `path_validate` reports
prefix/location conventions as WARNINGS (a project-side file lacking the
`test_` prefix, a share-side file carrying it), and the pairing map
below is advisory for agents promoting a test alongside its source.
Integration tests pair with no single source file and are free-form
within the test tree.

### Generic operations

`path_read`, `path_write`, `path_edit`, `path_list`, `path_move`,
`path_rename` and `path_delete` behave as an exact filesystem view over
the kind's roots. `patch` is off for all four kinds (whole-file authored
sources), and no kind registers a `test` capability.

Capabilities are NOT identical across the four kinds: the three SOURCE
kinds (`task`, `entity`, `entity_property`) offer validate + smoke +
promote, while `test_file` offers validate + promote and **no smoke**
(round-10 decision). For `test_file`, `validate` is the static check and
`run_test` is the executing check — `run_test` reports `passed` and the
exit status separately, so the old "ran OK even if the tests failed"
smoke verdict was redundant and was removed.

### validate

`path_validate` performs static shape checks on one file; it never
executes the target. Checks per kind:

- `task` — the source must parse and carry a `module <workflow>` wrapper
  (task files load into the <workflow> workflow module) plus a
  `task :name => :type do ... end` declaration. In the `tmp` location
  only, a missing `desc` is a warning, not an error (drafts carry their
  docs in a desc; promoted tasks move it to this README).
- `entity` — the source must parse, the top-level module must match the
  file name (`demo_widget.rb` → `module DemoWidget`), and the module must
  contain an `extend Entity` or `extend EntityWorkflow` line. Declaring a
  second top-level module is a warning.
- `entity_property` — the virtual path must be `<entity>/<property>`
  without a `.rb` suffix (a flat path is an error), the physical source must
  parse, the top-level module
  must match the entity segment of the path, the file must NOT carry an
  `extend` line (the entity file owns the extend), and it must declare
  `property :name => :type do ... end`; a declared property name that
  differs from the path's property segment is a warning. A typeless
  `property :plain do` is valid and dispatches as `:both`.
- `test_file` — the target must parse as Ruby, must require the
  test harness and declare at least one
  `<...> < Test::Unit::TestCase` subclass; a file that only requires the
  harness (no test class) validates with a warning, and the `test_`
  prefix/location conventions are WARNINGS, not errors (a project-side
  file lacking the `test_` prefix or a tmp-side file carrying it is
  reported, never rejected).
  The Test::Unit convention itself is advisory too: it is the shape the
  runner reports counts from, and what the regression suite pins, but
  `validate`'s reliable check is Ruby SYNTAX (AST parse), with the
  harness/class/prefix checks layered on top as warnings.

Test files are ordinary `test_file` resources authored with `path_write`;
execute them explicitly through the kind's `run_test` custom operation
(see `### test_file run_test` below and the [`## run_test`](#run_test)
task entry; for the removed legacy `path_test` operation see the
canonical note in the [Agent path kinds](#agent-path-kinds) intro). The
association between a
source draft and its paired test is an advisory naming convention: the
Path Engine promotes exactly ONE resource per `path_promote` call, and
the source kinds do not register paired-test relocation. Promote the test
itself through the `test_file` kind when you want it on the project side.
The advisory pairing map is:

| kind | tmp paired test | project paired test |
|---|---|---|
| `task` | `share/test/task/<name>.rb` | `test/<workflow>/tasks/test_<name>.rb` |
| `entity` | `share/test/entity/<name>.rb` | `test/<workflow>/entity/test_<name>.rb` |
| `entity_property` | `share/test/entity_property/<entity>/<entity>.<property>.rb` | `test/<workflow>/entity/<entity>/test_<property>.rb` |
| `helper` | `share/test/helper/<name>.rb` | `test/<workflow>/helpers/test_<name>.rb` |
| `integration` | `share/test/integration/<name>.rb` | `test/<workflow>/integration/test_<name>.rb` |

**Spelling rule (stated once).** The share side carries no `test_`
prefix and keeps the tier spelling (`share/test/task/greet_user.rb`,
`share/test/integration/rt.rb`); the project side adds the `test_`
prefix to the FINAL FILENAME only, carries intermediate directories
through unchanged, and renames exactly one tier directory (`task` →
`tasks`). Concrete examples: `task/greet_user` →
`test/<workflow>/tasks/test_greet_user.rb`; `entity/demo` →
`test/<workflow>/entity/test_demo.rb`; `entity_property/demo_widget/tag_palette`
→ `test/<workflow>/entity/demo_widget/test_tag_palette.rb` (HIERARCHICAL,
the round-10 layout; the flattened `test_<entity>_<property>.rb`
spelling is gone: underscore-bearing names made it non-invertible);
`integration/rt` → `test/<workflow>/integration/test_rt.rb`. The tier
list is open on the tmp side: any first segment other than
`entity_property` resolves under a same-named directory below
`share/test` (unknown tiers included); on the project side the known
tiers are rewritten, and an unknown first segment resolves under a
same-named directory below `test/<workflow>`. The documented tiers are
the recognized ones.

**Convention status.** The project-side
task/entity/entity_property spellings are implemented and pinned by the
regression suite (`test/<workflow>/test_path_kinds.rb` and
`test/<workflow>/test_path_kinds_roundtrip.rb`) but have no
precedent elsewhere in the checkout: they are the convention this README
records, still awaiting explicit ratification — flagged here rather than
asserted as settled policy. The `helper` project-side spelling
`test/<workflow>/helpers/test_<name>.rb` is likewise unratified: it was
derived by symmetry with the ratified `share/test/helper/` draft side and
has no precedent in the checkout. `integration` is round 9's own
convention on both sides, with the same uniform `test_` prefix as every
other tier.

`path_smoke` never runs a Scout job or inference. It exists on the three
SOURCE kinds only (`task`, `entity`, `entity_property`) — the round-9
contract is "the resource can be
initialized/constructed/registered", never "it executes":
`task` loads the real workflow in a fresh process and CONSTRUCTS the
task's job with placeholder values for its required inputs only, never
executing it; `entity` asserts the module is defined and registered in
`Entity::MODULES`, with no dispatch; `entity_property` asserts the
property is registered on its module and that its accessor resolves to an
`UnboundMethod` — the property body is never dispatched.
`test_file` has NO smoke (removed in round 10): the same evidence is
produced by `run_test`, which actually executes the tests in a fresh
process and reports `passed`, `ran`, the exit status and the exit
classification separately — so a FAILING test is visible as a failure,
not as a passing "it ran" smoke.

### test_file run_test

The `test_file` kind carries one custom operation, `run_test`, exposed to
the model as its own `run_test` tool. Inputs: `kind` (always
`test_file`), `path` (the virtual test-file path; `.` selects the whole
suite), `scope` (`file`, `directory` or `suite`; default `file`), optional
`location` (`tmp`, the default, or `project`) and optional
`timeout_seconds` (per-file, default 120). Each test file runs in its own
fresh Ruby process that loads the checkout's `workflow.rb` from the
checkout root — so LiveWorkflow live-loads every `share/` draft — and
then loads the test file. `scope: file` runs exactly one file;
`scope: directory` runs every test file under a path prefix;
`scope: suite` (conventionally with `path: "."`) discovers and runs every
test file in both locations. Empty discovery (no test files found) is an
error, not a clean zero. Per-file timeouts default to 120s (`file` and
`directory` scopes) or 300s (`suite` scope), overridable through
`timeout_seconds`. The result reports, per file, the exit status, a
classification (`clean_pass`, `assertion_failure`, `load_error`,
`timeout`), the test and assertion counts and the captured output, with
`passed` and `ran` as SEPARATE booleans (a failing test `ran` but did not
`pass`; a load error or timeout did neither), and the aggregate carries
`count`/`passed`/`failed`/`not_run` plus an overall `ok`. The
workflow-level [`run_test` task](#run_test) wraps the same runner for
programmatic use.

### promote

`path_promote` moves ONE resource from `tmp` to `project`. The
destination is declarative — always the kind's `project` root. The
engine authorizes both endpoints, refuses to overwrite an existing
destination unless you pass `overwrite: true`, and performs the move
itself; the refusal happens before the move, so a refused promotion
leaves the source file intact.
No ScoutCoder kind registers a `promotion_post_move` hook (round-10
step 6 removed the source kinds' paired-test relocation): promoting a
source draft moves ONLY that draft, and promoting a test moves only the
test. To land a source AND its paired test, promote each resource
yourself (the advisory pairing map above says where the test belongs);
the agent, not the engine, owns that coordination.

### Wiring after promotion (read this before promoting)

Promotion is a file move, not registration. Nothing under
`lib/<workflow>/tasks/` or `lib/<workflow>/entity/` is loaded
automatically:

- A promoted task is inert until a wiring line is added to `workflow.rb`,
  next to the existing ones. For example, wiring a promoted `greet_user`
  task:

  ```ruby
  require_relative 'lib/<workflow>/tasks/greet_user'
  ```

- A promoted entity or property file likewise needs its own wiring edit.
  LiveWorkflow loads only `share/` drafts; `workflow.rb` contains no
  loader for `lib/<workflow>/entity/` (that directory does not exist in
  the checkout today).

The wire-up is a deliberate source edit in every case; the path tools
never edit `workflow.rb`. A promoted task also moves its documentation:
remove the `desc` and write the entry in this README's `# Tasks` section
with `document_task` (see `## Testing` below).

### Trust boundaries

- **`run_test` executes UNSANDBOXED by design** (round-10 step 6). The
  `test_file` kind declares `sandbox: true` like the source kinds, but
  that flag governs which operations the agent may call, NOT how the
  custom operation executes: `run_test` is registered as a `:full`
  handler with `authorization: :read`, so the kind path is authorized as
  a read while the fresh child process runs test code with the authority
  of the caller — path authorization is not a process sandbox. Test
  source is trusted code; expose the `test_file` kind (and the
  `run_test` task) only to agents that may already execute trusted Ruby
  in this checkout.
- **No kind relocates files outside its roots.** The round-9
  paired-test relocation hooks were removed in round-10 step 6; nothing
  writes outside the kind roots on promotion anymore, and the agent
  owns cross-resource coordination.
- Entity-before-property ordering is a loader contract. A property file
  whose entity module has not been loaded fails loudly at load time — the
  underlying error surfaces; it is never a silent no-op — so property
  files always load after their entity files (see `## LiveWorkflow` for
  the combined lib/share load order). The smoke hook catches a
  wrong-order draft because it runs in a fresh process.
- Sandboxing is on for all four kinds: `entity`, `entity_property` and
  `test_file` declare `sandbox: true` explicitly, and the `task` kind
  relies on the engine default, which is `true`. Roots are pinned to
  absolute paths at
  registration — the recommended spelling is a relative Scout path such as
  `Scout.share.tasks` or `Scout.lib['<workflow>'].tasks`, pinned against
  the current project — and every operation is authorized against those
  pinned roots before any callback runs.

### When to use which

Rule of thumb: the path tools address ONLY the four registered kinds; for
any other file — wiring, docs, data, config — use Workspace.

Use the generators to create a draft from scratch —
[`define_task`](#define_task), [`define_helper`](#define_helper),
[`define_entity`](#define_entity) and
[`define_entity_property`](#define_entity_property) add the enclosing
module and scaffolding and refuse to overwrite an existing file. Use the
path tools to manage the lifecycle of a draft that already exists:
`path_write` stores whole-file content you author, and the remaining
tools read, edit, validate and promote what is there (plus `run_test` on
the `test_file` kind; smoke exists on the source kinds only). See
the `# Tasks` entries for generator input formats.

Worked example, one direction each way:

- Authoring a new task draft `greet_user`: `path_write kind=task
  path=greet_user` puts it at the right root (`share/tasks/`), with no
  extension to remember, where `path_validate` checks its shape
  (`module <workflow>` wrapper plus `task` declaration) and a workflow
  reload registers it. The Workspace `write` equivalent
  (`write share/tasks/greet_user.rb`) requires knowing the physical
  layout, validates nothing, and registers nothing by itself.
- Editing `workflow.rb` to wire a promoted task: there is no virtual kind
  for wiring, docs, data or config; use Workspace `read`/`write`/`patch`
  on the real file and retest from a fresh process.

### Lifecycle

The intended loop for one artifact:

1. `path_write` the draft at its `tmp` location.
2. `path_validate` for shape checks.
3. `path_write` the paired test as a `test_file` resource, then `run_test`
   it (file scope) to see it pass in a fresh process.
4. `path_smoke` (SOURCE kinds only) to confirm the draft
   initializes/registers when the real workflow loads; for `test_file`
   resources `run_test` is the executing check — there is no smoke.
5. `path_promote` to move the draft to the project side — then promote its
   paired test SEPARATELY through the `test_file` kind (promotion moves
   one resource; nothing auto-relocates the test).
6. Wire it into `workflow.rb`; only then is the promoted artifact live.


## Testing and execution

Choose the runner by what you are trying to establish:

- Use `path_validate` to check a virtual resource's static shape and syntax.
- Use `path_smoke` on `task`, `entity`, or `entity_property` to verify initialization/registration without executing domain behavior.
- Use `run_test` for a test file managed by the `test_file` kind, including directory or suite scopes.
- Use `run_task_test` / `run_helper_test` when their specialized authoring-task conventions fit the source.
- Use `run_task` to exercise a workflow task directly through the normal Scout job system. It is a behavior probe, not a substitute for an assertion-based test.
- Use `job_info` and `job_status` to inspect an existing job without re-running it.

### Authoring and running tests

Test code is ordinary trusted program code. The general test-file lifecycle is:

1. Create or inspect the source resource and use `path_validate`.
2. Write the paired test through `path_write` on kind `test_file`. Virtual examples are `task/greet_user`, `entity/demo_widget`, `entity_property/demo_widget/tag_palette`, and `integration/round_trip`. Do not include the physical `share/test/` or `test/<workflow>/` roots or a `.rb` suffix in the virtual path.
3. Run the test with `run_test` at `scope: file`. Widen to `directory` or `suite` only when a broader check is useful. A zero-file discovery is an error, not a passing empty suite.
4. For source kinds, separately use `path_smoke` when load/registration needs verification. A passing smoke check does not prove behavior.
5. If the source and test should be permanent, promote each resource separately with `path_promote`. The engine moves one resource per operation; it does not move its paired test for you.
6. After promoted source is wired into `workflow.rb`, re-run the test or relevant suite from a fresh process.

For task drafts under `share/tasks/`, `author_task_test` and `run_task_test` remain useful when their convention fits. The paired test is `share/test/task/<task_name>.rb`. For shipped task code under `lib/<workflow>/tasks/<file>.rb`, the specialized convention is `test/<workflow>/tasks/test_<file>.rb`. Helper drafts can use `author_helper_test` / `run_helper_test`; helper code runs in a task Step context, so test through a disposable task/Step as appropriate. These specialized tasks coexist with `test_file` and its general `run_test` runner; choose one convention for the test you are authoring rather than creating duplicate tests without a reason.

A test file for the generic runner uses the Test::Unit shape:

```ruby
require 'test/unit'

class MyTaskTest < Test::Unit::TestCase
  def test_example
    assert_equal 2, 1 + 1
  end
end
```

`run_test` mechanics (fresh per-file Ruby process, `workflow.rb` load, exit classification, `passed` vs `ran`) are documented once in [`### test_file run_test`](#test_file-run_test) and the [`## run_test`](#run_test) task entry. Both specialized and general test runners start fresh processes, but Scout job/Step results are persistent and are not automatically cleared; see [Fresh process versus fresh result](#fresh-process-versus-fresh-result).

The test-file path convention (a test mirrors its tested file's path under the test tree) is ScoutCoder doctrine, with the pairing map in [Agent path kinds](#agent-path-kinds); scout-rig's suite is the worked example — scout-rig `doc/user/TestingAndPackaging.md` § "Test suite layout mirrors `lib/`" (that document is scout-rig's own build/test/packaging story, not a general conventions reference).

### Understand execution and sandbox boundaries

Path Engine authorization is not a process sandbox, and `run_test` intentionally executes trusted test code unsandboxed; the canonical statement is [Trust boundaries](#trust-boundaries) under [Agent path kinds](#agent-path-kinds), with engine-level semantics in scout-ai `doc/developer/Sandbox.md` § "1. Is this tool sandboxed?" and `doc/developer/PathEngine.md` § "8. Callback contract and trust boundary".

`run_task` executes a normal Scout workflow job. Use it to test task behavior through Scout's standard execution path, not to try to perform arbitrary file operations through a file-oriented tool. Do not assume `run_task` is OS-sandboxed unless a separate runtime boundary explicitly establishes that. `run_task` returns whether a result was replayed; pass `clean: true` when the addressed job must be recomputed.

The distinction can avoid misleading sandbox-related failures: a test that needs ordinary workflow loading or runtime behavior should be run by `run_test` or a normal workflow job by `run_task`, rather than being coupled to Path Engine read/write operations. Timeouts and output capture are operational controls, not process isolation. Only execute trusted code and pass explicit inputs.

A test should assert the intended behavior, including error and edge cases where relevant; syntax, registration, and mere process exit are not sufficient evidence of correctness.

### Running a task directly

`run_task` takes `workflow`, `task`, JSON text in `inputs` (default `{}`), and `clean` (default `false`). It executes synchronously and returns status, output, job path, replay status, and captured error. Inspect inputs and dependencies before execution when the task contract is not obvious:

```ruby
ScoutCoder.job(:task_inputs, nil,
  workflow: 'ComputerUse',
  task: 'read'
).run

ScoutCoder.job(:run_task,
  workflow: 'ComputerUse',
  task: 'read',
  inputs: '{"path":"README.md"}',
  clean: true
).run
```

Use `job_info` or `job_status` when you already know the workflow, task, and inputs for an existing job and only need to inspect it.

**Where job outputs land.** `run_task` jobs persist under the checkout's `var/jobs/<Workflow>/<task>/<id>/` (relative to the project root of the workflow that ran the job); the result receipt returns the job path, its short path, and the replay status. Inspect without re-running via `job_info`/`job_status`, and pass `clean: true` when a recompute is required instead of hunting for outputs by hand.

### Documentation during promotion

While a task lives under `share/tasks/`, its documentation is normally in its `desc`. When promoted into `lib/<workflow>/tasks/`, follow the project's convention: remove the draft-only `desc` and document the shipped task in this README's `# Tasks` section with `document_task`. Do not assume this documentation change happens automatically from file promotion.

The `ScoutCoder:` comment convention (see the intro) closes its loop here: promoted `ScoutCoder:` comments are the raw material for `document_task` entries and for repo-documentation improvements. When a comment's fact is settled, move it into the README entry or the relevant repo doc instead of letting discoveries accumulate as comments.


# Tasks

## define_entity
Create and register an entity module in this checkout

Inputs: required `entity_name` and trusted Ruby `definition`; optional `base`
(default `Entity`, or `EntityWorkflow`) and `identifiers` (TSV contents).
Writes `share/entities/<entity>.rb` and reloads `workflow.rb` to register the
module. See [Authoring <workflow> entities](#authoring-scoutcoder-entities)
above for the input-body format, identifier-file conventions, limitations,
and examples.

## define_entity_property
Add one property to an existing <workflow> entity

Inputs: required `entity_name`, `property_name`, and trusted Ruby `definition`
containing a matching `property :<property_name>` declaration. Writes
`share/entity_properties/<entity>/<property>.rb`, reloads the workflow, and
checks that the property is registered. See
[Authoring <workflow> entities](#authoring-scoutcoder-entities) above.

## list_entities
List all known entity modules and metadata

Takes no inputs. Returns a sorted array of entity records covering every
module that has extended `Entity` in the current process, deduplicated, so
framework modules such as `AssociationItem` are listed beside any ScoutCoder
entities. Each record includes annotations, formats, identifier files,
properties, inferred source paths, effective dispatch, persistence status, and
detected base kind. Source paths are inferred from the conventional
`lib/<workflow>/entity/` layout and are absent for framework modules; dispatch
is inferred from generated method names, with the alias limitations described
in [Authoring <workflow> entities](#authoring-scoutcoder-entities) above.

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
Create a Scout workflow task draft

Inputs: `task_name`, `definition`, and optional `export_type` and `workflow`.
The definition is Ruby Scout DSL source: author any needed `desc`, `input`,
and `dep` declarations and the matching `task :name => :type do ... end`.
Inputs and dependencies are not inferred from the task body. The definition
may declare additional tasks. The generator supplies the enclosing workflow
module and, by default, `export :<task_name>`; set `export_type` to
`export_exec` or `none` to change or omit that export. The task name must match
`[a-z][a-z0-9_]*`, and the source must declare that task. It is syntax-checked
and written to `share/tasks/<task_name>.rb` without overwriting an existing
file. After writing it, the task reloads the workflow and verifies
registration. Source is trusted Ruby code executed during loading; a load or
registration failure can occur after the file is written.

Example definition:

```ruby
definition = <<~'RUBY'
  task :greeting_prefix => :string do
    'Hello'
  end
  desc 'Greet someone'
  dep :greeting_prefix
  input :name, :string, 'Name to greet', 'World'
  task :greet => :string do |name|
    "#{step(:greeting_prefix).load}, #{name}!"
  end
RUBY

ScoutCoder.job(:define_task,
  task_name: 'greet',
  definition: definition
).run
```

Use `author_task_test` and `run_task_test` for the test loop. A task's draft
documentation lives in its `desc`; when promoted into `lib/`, remove that
`desc` and document it here with `document_task`.

## define_helper
Create a Scout workflow helper draft

Inputs: `helper_name`, `definition`, and optional `workflow`. The definition
must include the matching `helper :<helper_name> do |args...|` declaration
and body. The generator supplies the enclosing workflow module but does not
infer the helper's arguments or behavior. The name must match
`[a-z][a-z0-9_]*`; the source is syntax-checked and written to
`share/helpers/<helper_name>.rb` without overwriting an existing file. The
workflow reloads and verifies registration. Source is trusted Ruby code run
during loading; a load or registration failure can occur after the file is
written.

Example definition:

```ruby
definition = <<~'RUBY'
  helper :join_parts do |left, right|
    "#{left}-#{right}"
  end
RUBY

ScoutCoder.job(:define_helper,
  helper_name: 'join_parts',
  definition: definition
).run
```

Helpers run in a workflow Step context; for tests, declare a disposable task
that calls the helper and run that task's Step.

## define_python_task
Create a Python-backed Scout task source file

Inputs: `task_name`, `python_source`, and optional `workflow` (default
`ScoutCoder`). The name must match `[a-z][a-z0-9_]*`; submitted Python
source is written to `python/tasks/<task_name>.py` in the target workflow
checkout. The tool supplies the framework import envelope—a top-level
`import scout`—when the source lacks one, placing it after any module
docstring and `from __future__` imports. No other Python task code is
synthesized. The file name selects the Python source file; registered
function names become the Scout task names and need not be the file name.

### Framework-provided setup vs. user-authored task code

The only authoring boilerplate this tool supplies is the top-level
`import scout`. That import makes the framework API available; it does not
declare a task. Authors must still write each Python function header/signature and action
body, and call `scout.task(function)` to explicitly register the function. For example,
include `scout.task(greet)` after defining `greet`; a function definition by
itself is not registered. In this Python task API, inputs are described by the
authored function signature; `define_python_task` does not infer or generate
functions, signatures, registrations, dependencies, or task declarations.
This boundary is intentional.

Minimal complete registration shape (author the function and registration;
the generator supplies `import scout` only if it is missing):

```python
import scout

def greet(name: str = "World") -> str:
    return f"Hello, {name}!"

scout.task(greet)
```

When `import scout` is omitted from submitted source, the generator inserts it;
the remainder of this example is still authored by the caller. This complete
function-and-registration format matches Scout-rig's
[Python task authoring guide](../scout-rig/user/DefiningPythonTasks.md).
The task rejects empty or syntactically invalid Python, files that do not
register task metadata, and any existing target (including a symlink). It
uses the configured `PYTHON` executable or `python3` and the local
`~/git/scout-rig/python` package to inspect `--scout-metadata`, then reloads
the workflow and checks each discovered function name is registered. When
the import was missing, the saved file includes that framework-supplied
import and the result reports `framework_import_added: true`; otherwise the
submitted source remains unchanged and the flag is false. If metadata
inspection or reload fails after creation, the candidate remains on disk for
inspection; the error identifies that state. This executes trusted Python
source during metadata inspection.

## author_python_task_test
Create a Python unit test for an existing Python task file

Inputs: `task_name` and `test_source`. Requires
`python/tasks/<task_name>.py`; writes complete Python source unchanged to
`python/test/test_<task_name>.py`. The test source must be non-empty and pass
Python AST syntax validation (using `PYTHON` or `python3`). Existing targets,
including symlinks, are never overwritten. The source is not executed or
otherwise checked as a `unittest` test; this tool does not add Python test
discovery or execution behavior.

## author_helper_test
Create a test for an existing ScoutCoder-authored workflow helper

Inputs: `helper_name` and `test_source`. Writes a syntax-checked test to
`share/test/helper/<helper_name>.rb`; existing tests are never overwritten.
Because workflow helpers execute in a task Step context, helper tests should
declare a disposable fake task that calls the helper, run that task's Step,
and assert its result. Test source is trusted Ruby code and is not OS-sandboxed.

## run_helper_test
Run an authored helper test in a fresh Ruby process

Inputs: `helper_name` and positive `timeout_seconds` (default 120). Loads the
current workflow and authored helper files, then runs the paired test. Returns
pass/fail, exit status, captured output, and timeout status. Persistent Step
results are not cleared automatically; tests should clean their fake-task Step
when freshness matters.

## author_task_test
Create a test for an existing ScoutCoder-authored task

Inputs: `task_name` and `test_source`. The paired test is written following
the task's source location: `share/test/task/<task_name>.rb` for tasks
authored under `share/tasks`, or `test/<workflow>/tasks/test_<file>.rb` for
tasks in `lib/<workflow>/tasks`. The task name must match
`[a-z][a-z0-9_]*`, and the corresponding task source must exist. The source
is Ruby syntax-checked before writing; an existing test file is never
overwritten. The test is not run during creation. Use `run_task_test` to
execute it. Test source is trusted code and is not OS-sandboxed.

## run_task_test
Run an authored task test in a fresh Ruby process

Inputs: `task_name` and positive `timeout_seconds` (default 120). Loads the
current `workflow.rb` (including every authored task file), then executes
the paired test - `share/test/task/<task_name>.rb` for tasks under `share/tasks`,
or `test/<workflow>/tasks/test_<file>.rb` for tasks in `lib/<workflow>/tasks`
- with `lib/` on the Ruby load path. Returns pass/fail, exit status, standard
output and standard error, timeout status, and the invocation details. A fresh
Ruby process loads current source and task discovery, but does not clear
persistent Scout job caches; tests should explicitly clean jobs where
freshness matters.

## run_test
Run test files through the `test_file` path kind

Inputs: `path` (the `test_file` virtual path; `.` for the whole suite),
`scope` (`file`, `directory` or `suite`; optional, default `file`),
optional `location` (`tmp` or `project`, default `tmp`), and optional
`timeout_seconds` (integer 1..3600; default 120 for `file` and `directory`,
300 for `suite`). The target is resolved through the agent's `test_file`
kind, then dispatched according to scope. Each selected file runs in its own
fresh Ruby process, which loads the checkout's `workflow.rb` and then the
test file, with `lib/` on the load path.

**Execution is unsandboxed.** The test path is authorized as a read resource,
but the child process runs trusted test code with the caller's authority. See
[Development doctrine and tool selection](#development-doctrine-and-tool-selection)
and [Trust boundaries](#trust-boundaries). Discovering zero test files is a
`ParameterException`, not a passing empty suite. The result reports per-file
exit status/classification (`clean_pass`, `assertion_failure`, `load_error`,
`timeout`), test/assertion counts, captured output, and distinct `passed`
and `ran` fields. Persistent Scout job caches are not cleared automatically.

## document_task
Add or replace a task entry in the <workflow> README.md Tasks section

Inputs: `task_name` and `documentation`. Replaces the existing
`## <task_name>` entry, or appends a new entry at the end of the `# Tasks`
section. The documentation is Markdown body text placed beneath the generated
heading.

This is the promotion step for task documentation: an authored task carries
its documentation in a `desc` while it lives under `share/tasks`, and when it
is promoted into `lib/<workflow>/tasks` the `desc` is removed and the entry is
written here with `document_task`. See the Testing and development notes above
for the promotion loop.

## list_tasks
List tasks declared by a workflow

Inputs: `workflow` (required string). Returns the sorted tasks with each
task's name, description, result type, directly declared inputs, source
location, and a dependency summary. The dependency summary reports the static
declarations and whether a dynamic dependency block is present; it does not
expand dynamic blocks into a complete dependency list. Use `task_inputs` to
inspect inputs propagated from dependencies as well, and `task_dependencies`
for the dependency detail.

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
with the supplied inputs through ordinary Scout job execution and returns
compact JSON with status, output, job path and short path, whether the result
was replayed from cache, and any captured error. Set `clean: true` to clean
the addressed job before running. This is a task-execution surface, not a
test runner or an implicit OS sandbox; see [Testing and execution](#testing-and-execution).

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
info file, status, timestamps, messages, and exception metadata when available. It does not run the task.

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

A source is resolved by first looking for an existing `~/git/<name>` directory and using it directly when present; otherwise the name is loaded as a workflow with network autoinstall disabled and its checkout root is derived from the workflow `libdir` (the parent directory when `libdir` ends in `lib`, `libdir` itself otherwise). Names matching neither raise a controlled `ParameterException` ("Unknown repo or workflow: <name>"). This is the normal follow-up to `help_list_repos` or `help_list_workflows`: agents inspect the available document identifiers first and then request the specific files that match the concepts they need.

Only markdown (`.md`) files are listed. When a source has several `doc*` directories holding the same relative paths, the identifiers collide and the last file from the glob wins.

## help_get_repo_document
Return the contents of a documentation file from one Scout repository or workflow

The `repo` input has the same semantics as in `help_list_repo_documents`: a required free string (declared with `nofile: true`) naming a Scout repository under `~/git` or any installed Scout workflow. The `document` input (also `nofile: true`) is one of the identifiers produced by `help_list_repo_documents`.

The task resolves the document through a fallback chain: the literal `README.md` of the source, an exact identifier match from the listing, a `doc*/**/<document>` glob, a direct `research/` or `doc/` path, and finally a `research/**/<document>` glob. The full text of the first match is returned.

If no step of the chain matches, the task raises a `ParameterException` whose message lists up to 10 available documents, which makes failures explicit and easy for an agent to recover from. Treat that exception as a normal miss, not a crash.

This is the lowest-level documentation lookup task. Use it when an agent already knows the exact document it needs and wants the raw markdown to read or quote.

## help_overview
Generate a guide to the available Scout framework documentation

Relatively expensive: prefer the deterministic listing and retrieval
tasks (`help_list_repos`, `help_list_repo_documents`,
`help_get_repo_document`) in automated checks, and reach for
`help_overview` only when they cannot localize the topic.

This task builds a synthetic overview by reading the `README.md` and `doc/**/*.md` files of the known Scout repositories and asking an LLM agent to produce a markdown guide for other agents. The result is not a static hand-written file; it is generated from the currently available documentation and can evolve as the source repositories evolve. It aggregates the fixed `REPOS` list only, not installed workflow sources, and it issues one model call over all those documents.

Because the task drives an agent through the Scout-AI agent helper, it needs the agent machinery available in the calling context; in a plain workflow process without that tooling the run fails early.

In practice this is useful when an agent has a broad question such as where to learn about workflows, entities, TSV processing, command execution, or LLM integration. The answer should help narrow the search before calling `help_get_repo_document` on specific files.

## help_workflow
Return the markdown documentation for a workflow

The `workflow` input names any workflow that can be loaded through `Workflow.require_workflow`. The task loads it with network autoinstall disabled (so it must already be available locally) and returns its `documentation_markdown`: the `workflow.md` or `README.md` found next to the workflow `libdir`, as markdown text.

This is useful both for introspection and for tool discovery. For example, an agent can read the documentation for `ScoutCoder` itself or query the docs of another installed workflow before interacting with it.

## help_list_workflows
List the workflows installed and available to ScoutCoder

This task unions `Workflow.installed_workflows`, a purely local scan of the `workflows` pathmap that never triggers network autoinstall, with the workflow modules already loaded in the current process. The combined list is deduplicated and sorted, and the local scan is wrapped in a rescue so the task never crashes.

It is the discovery step for workflow names: any name it returns is usable as the `repo` input of `help_list_repo_documents` and `help_get_repo_document`, which then read the workflow's own `README.md`, `doc*/`, and `research/` documentation.
It is the discovery step for workflow names: any name it returns is usable as the `repo` input of `help_list_repo_documents` and `help_get_repo_document`, which then read the workflow's own `README.md`, `doc*/`, and `research/` documentation.

## reverse

Footnote (demo/smoke task, not a first-class capability): reverses the input string; exists only to smoke-test the workflow's task machinery.

