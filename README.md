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
- scout-gear `doc/developer/EntitySystem.md` § "Entity definition" and "Property dispatch" — the entity/property machinery the entity path kinds' validators check against.
- scout-gear `doc/user/CachingData.md` § "Where persistence lives (ecosystem split)" — where job/Step results actually persist.
- Workspace `doc/user/TSV.md` — TSV task semantics in the Workspace workflow (local doc).

## Contents

- [Development doctrine and tool selection](#development-doctrine-and-tool-selection) — tool table, layered validation, execution vs file authorization, fresh process vs fresh result, promotion.
- [Layout conventions](#layout-conventions) and [LiveWorkflow](#liveworkflow) — directory layout and the `share/` draft-loading contract.
- [Authoring ScoutCoder entities](#authoring-scoutcoder-entities) — entity, property and Python task authoring formats, [property dispatch types and receiver shape](#property-dispatch-types-arity-and-receiver-shape), [production versus development dispatch](#production-versus-development-dispatch).
- [Agent path kinds](#agent-path-kinds) — kinds and roots, [kind locations](#kind-locations), [validate](#validate), [test_file run_test](#test_file-run_test), [probe run_probe](#probe-run_probe), [promote](#promote), [wiring after promotion](#wiring-after-promotion-read-this-before-promoting), [trust boundaries](#trust-boundaries), [when to use which](#when-to-use-which).
- [Testing and execution](#testing-and-execution) — choosing a runner, [authoring and running tests](#authoring-and-running-tests), where job outputs land, [running a task directly](#running-a-task-directly), [documentation during promotion](#documentation-during-promotion).
- [# Tasks](#tasks) — per-task reference entries: test runners, probe runner, job inspection, documentation lookup.

## Development doctrine and tool selection

Use the tool whose responsibility matches the work. ScoutCoder provides Scout-aware discovery and authoring; the Path Engine provides authorized operations on registered virtual resources; Workspace is for general repository edits; task and test runners execute code through the ordinary workflow/process environment.

| Need | Preferred tool | Boundary |
|---|---|---|
| Understand existing workflow behavior | `help_workflow`, `list_tasks`, `task_inputs`, `task_dependencies`, `task_code`, `list_entities` | Inspection; no behavior should be inferred from a task name alone |
| Create a workflow task draft | `path_write` on the `task` kind | Writes under `share/tasks/` at the kind root, with no extension to remember; a workflow reload registers the draft, and the trusted draft may execute while loading |
| Manage a registered virtual source/test file | `path_kinds`, then `path_read`, `path_write`, `path_edit`, `path_list`, `path_validate`, `path_smoke`, `path_promote` as supported by the kind | Path authorization covers the addressed resource and configured roots |
| Run a test file | `run_test` for the `test_file` kind | Execution occurs in a fresh process, but `run_test` is deliberately unsandboxed |
| Run a probe snippet | `run_probe` on the `probe` kind | Fresh UNSANDBOXED child running trusted code with the caller's authority; see [probe run_probe](#probe-run_probe) |
| Exercise a workflow task directly | `run_task` | Uses ordinary Scout job execution; check cache replay and clean the addressed job when needed |
| Edit existing source, wiring, tests, or docs | Workspace | The path tools address ONLY the six registered kinds; for any other file — wiring, docs, data, config — use Workspace. Inspect the exact diff and retest; do not assume Workspace and workflow tools share an execution sandbox |

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
  `lib/ScoutCoder/entity/` (currently empty), the entity-authoring
  support consumed by `list_entities` (`tasks/entity_tools.rb`), and the
  shared runner/support modules (`test_file_support.rb`,
  `probe_support.rb`, `python_task_support.rb`; the legacy task-test and
  helper-test supports were retired in round 13 together with their
  unimported task files).
- `share/` - the authoring-drafts convention. `share/tasks/`,
  `share/helpers/`, `share/entities/` and `share/entity_properties/` hold
  draft definitions loaded live by Scout-gear's `LiveWorkflow` on every
  workflow reload, in ScoutCoder's own checkout and in any other workflow
  that extends it.
  ScoutCoder's own four draft directories are currently empty, so extending
  is a no-op here today.
- `share/test/` - test-file drafts, including the conventional
  `task/`, `helper/`, `entity/`, `entity_property/`, `python_task/` and
  `integration/` tiers. They are never loaded by `LiveWorkflow`; the
  `test_file` path kind and `run_test` own their lifecycle.
- `share/probes/` - probe snippets (round 12): unsandboxed, one-off Ruby
  investigations of the Scout framework itself, managed by the `probe`
  path kind and executed by `run_probe`. Never loaded by `LiveWorkflow`
  and never executed by any generic path operation.
- `share/entity/` - identifier TSVs (`<entity>.identifiers.tsv`) written
  by the entity-authoring flow. Data, not code: they are registered by
  the generated entity definition and never loaded as Ruby.
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
drafts follow their distinct module/body formats described below.

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

Entity modules and their properties are authored as DRAFTS through the
`entity` and `entity_property` path kinds: `path_write kind=entity
path=<name>` writes `share/entities/<name>.rb` and `path_write
kind=entity_property path=<entity>/<property>` writes
`share/entity_properties/<entity>/<property>.rb`. Scout-gear's
`LiveWorkflow` loads entity drafts before property drafts on every
workflow reload; the shipped built-in entity tree is separately located
under `lib/<workflow>/entity/` and is not loaded today.

Entity-TYPE names are CamelCase: they must match `[A-Z][A-Za-z0-9]*` (e.g.
`DemoWidget`, or the all-caps acronym `TF`); a name such as `DemoWidget`
maps to the top-level `::DemoWidget` module. Property names stay
snake_case (`[a-z][a-z0-9_]*`).

LEGACY ACCEPTANCE: an old-pattern snake_case entity name
(`[a-z][a-z0-9_]*`, e.g. `demo_widget`) still validates, with a warning
that names both spellings; the virtual path keeps the user's spelling
(`share/entities/demo_widget.rb` stays `demo_widget`), and the module
constant is the Rule-B camelization — `demo_widget`.split('_').
map(&:capitalize).join → `DemoWidget`. Two cases are HARD errors: a snake
name whose Rule-B constant collides with the constant of a coexisting
CamelCase draft (`demo_widget.rb` + `DemoWidget.rb` both → `DemoWidget`),
and two snake names whose Rule-B constants collide (`a_b` + `a__b` both →
`AB`). Ratified by the decision artifact
`reports/entity-case-convention-decision.md`.

The entity base is the `extend Entity` (or `extend
EntityWorkflow`) line INSIDE the entity file — a hand-authored draft
carries its own `module` wrapper and its own extend line, because
`Kernel#load` evaluates the file at top level; `path_validate`
(`entity` kind) checks exactly this shape: the top-level module must
match `constant_name` of the file name (`DemoWidget.rb` → `module
DemoWidget`, and `TF.rb` → `module TF`, optional leading `::` — a legacy
`demo_widget.rb` must declare `module DemoWidget`, the Rule-B constant)
and must contain the extend line. An `entity_property`
draft conversely must NOT carry an extend line (the entity file owns
the extend) and must declare `property :name => :type do ... end`;
`path_validate` checks that too; its entity segment follows the same
name rules (CamelCase canonical, legacy snake accepted with the warning).
A typeless `property :plain do` is
valid and dispatches as `:both`.

The generated form of a complete entity file looks like this (the
identifiers call is included only when an identifier TSV exists beside
it under `share/entity/<entity>.identifiers.tsv`):

```ruby
# share/entities/DemoWidget.rb — the COMPLETE file a draft must be.
module DemoWidget
  extend EntityWorkflow
  add_identifiers Path.setup(File.expand_path('../../entity/DemoWidget.identifiers.tsv', __dir__))
  annotation :organism
end
```

The TSV header fields name its identifier formats (e.g. `#ID,Name`);
conventions: scout-gear `doc/user/WorkingWithEntities.md` § "Format and
identifier translation". The `add_identifiers` path is constructed
relative to the entity definition file, so registration does not depend
on the process's current working directory. Identifier files are
resource data, never loaded as Ruby, and a draft should not overwrite
an existing one casually.

A property draft is the property declaration plus body, wrapped in the
SAME entity module:

```ruby
# share/entity_properties/DemoWidget/label.rb
module DemoWidget
  property :label => :single do |prefix, suffix|
    "#{prefix}#{self}#{suffix}"
  end
end
```

### Property dispatch types (arity) and receiver shape

The four property types — `:single`, `:array`, `:multiple`, `:both` (the
default when the declaration is a bare `property :name do`) — decide both
what the block receives and what the caller gets back. Scout-gear authority:
`doc/user/WorkingWithEntities.md` § "Properties" (the two up-front behaviors)
and `doc/developer/EntitySystem.md` § "Property dispatch" (the full matrix,
including the single-receiver return cell).

| type x receiver | block input (self) | return shape |
|---|---|---|
| `:single`, single entity | the entity itself, once | block result |
| `:single`, list receiver | each member, once per member | Array of per-member results |
| `:array`, list receiver | the whole list, once | block result, unchanged |
| `:array`, single entity | one-element array (`make_array`, property.rb:141) | **collapsed**: `Array === res ? res[0] : res[self]` (property.rb:142) |
| `:multiple`, list receiver | the whole list, once | Array: `responses.values_at(*self)` (property.rb:98) |
| `:multiple`, single entity | one-element array (`make_array`) | collapsed `res[0]`/`res[self]`, like `:array` |
| `:both`, single entity | the entity as-is | block result |
| `:both`, list receiver | the whole list, once (no wrapper; property.rb:114) | block result |

Two traps the probe evidence confirmed (Cortex
`research/w3-w5-verified-facts.md`):

- A single receiver on an `:array`/`:multiple` property **wraps the block's
  self into a one-element array but collapses the return value to its first
  element** (property.rb:141-142). The "cast into an array" intuition is right
  only about the block receiver; the return is `res[0]`. Use
  `mod.setup(id).make_array` to get the full Array result instead.
- `:multiple`'s generated method probes the per-item cache first and computes
  only missing members (property.rb:74-96), but **the cache layer itself is
  `Entity.persist`** (property.rb:149-154, dir `var/entity_property`), which
  wraps every arity's real method (property.rb:108-110) — and it caches ONLY
  when `persist` is declared; otherwise options are `{persist: false}` and
  nothing is persisted. `:single2array`/`:array2single` are aliases of
  `:single`/`:array` (property.rb:51-54).

`path_write kind=entity_property` records NO arity metadata: the generator
`EntityDefinitionSupport.property_source` (entity_tools.rb:292-298) only wraps
the authored text, the property type lives inside the `property :x => :type`
declaration, and `effective_dispatch` (entity_tools.rb:394) later INFERS the
type from the registered accessor. The draft carries the type; nothing else
records it.

### Production versus development dispatch

There are two distinct surfaces for dispatching a property. A production
dispatch surface — such as Semantics' `entity_property` task — dispatches
what its own process loaded; it deliberately does NOT reload drafts defined
after its process started, so a fresh `share/` draft is invisible to it until
that process reloads the workflow. That is expected behavior, not a defect.
Development verification of a fresh draft therefore goes through `run_probe`
(see [probe run_probe](#probe-run_probe)): its fresh child preloads the
owning checkout's `workflow.rb`, so LiveWorkflow live-loads the current
`share/` drafts and the probe dispatches the property exactly as a
newly-loaded process would.

Scout-gear's `LiveWorkflow` loader loads entity drafts before
recursively loading property drafts in sorted order (see Layout
conventions and LiveWorkflow for the combined order). Entity-before-
property ordering is a loader contract: a property file whose entity
module has not been loaded fails loudly at load time, never silently.
`path_validate` checks names, Ruby syntax, and the shape declarations;
it does not prove the semantics of the Ruby code. Since the source
executes during workflow loading and reload, treat it as trusted code,
not sandboxed input.

### Entity and Python task authoring formats

These examples show the file shapes the path kinds and validators
expect; they are complete file bodies, not generator inputs.

- An entity draft is a complete module file: `module <Entity>` wrapper,
  the `extend Entity` / `extend EntityWorkflow` line, then annotations
  and helper declarations. Example:

  ```ruby
  module DemoWidget
    extend EntityWorkflow
    annotation :organism
  end
  ```

  The acronym case (the `TF` example that motivated the CamelCase
  switch): a short all-caps type stays all-caps, and the module name is
  identical to the file name:

  ```ruby
  # share/entities/TF.rb
  module TF
    extend Entity
  end
  ```

- A property draft is a `property :<name> => :<dispatch_type> do
  |args...| ... end` declaration and executable body, wrapped in the
  existing entity module:

  ```ruby
  property :hello => :single do |prefix, suffix|
    "#{prefix}#{self}#{suffix}"
  end
  ```

- For a Python task draft, author the function definitions and explicit
  `scout.task(function)` registration; the file needs its own top-level
  `import scout` (after a module docstring and `__future__` imports
  when present). It supplies no function or task declaration. For
  example:

  ```python
  import scout

  def greet(name: str = "World") -> str:
      return f"Hello, {name}!"

  scout.task(greet)
  ```

Identifier TSVs live at `share/entity/<entity>.identifiers.tsv`. One
must be non-empty and have a header accepted by `TSV.parse_header`
naming the identifier formats it maps (for example, `#ID,Name`;
identifier-file conventions are documented once in scout-gear
`doc/user/WorkingWithEntities.md` § "Format and identifier
translation"). The entity definition registers that path with
`add_identifiers` at load time. Draft files live under `share/entities/`
and `share/entity_properties/`; the built-in module/property loader for
`lib/<workflow>/entity/` is a separate convention. Do not relocate
drafts to the built-in tree expecting the LiveWorkflow loader to
discover them.

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
they are resource data registered by the entity definition's
`add_identifiers` call. Entity and property drafts are created through the
`entity` / `entity_property` path kinds and loaded live by Scout-gear's
`LiveWorkflow` under `share/entities/` and `share/entity_properties/`.
These are separate loading conventions; do not relocate drafts to the built-in
tree expecting the LiveWorkflow loader to discover them.

## Agent path kinds

ScoutCoder registers six path kinds on the scout-ai agent path engine:
`task` (Scout workflow task files), `entity` (Scout entity module files,
one file per entity), `entity_property` (entity property files,
addressed through nested `<entity>/<property>` virtual paths),
`python_task` (Scout Python task source files, one `.py` per task),
`test_file` (unit and integration test files, addressed through tier
paths such as `task/greet_user`, `integration/round_trip` or
`python_task/my_task`) and `probe` (unsandboxed ScoutCoder-only Ruby
snippets for investigating the Scout framework itself, addressed as a
bare name under `share/probes/`). They
expose the authoring surfaces of the current project's own workflow
(ScoutCoder's own definitions live in `lib/ScoutCoder/path_kinds.rb`;
the kinds are defined by the workflow of the current directory) as virtual
filesystems an agent operates
with the generic `path_*` tools: the `path_kinds` listing tool plus one
tool per operation — `path_read`, `path_write`, `path_edit`, `path_list`,
`path_move`, `path_rename`, `path_delete`, `path_validate`,
`path_smoke` and `path_promote` — with no per-kind tool fan-out, plus
the two custom operations installed as their own tools: the
`test_file`-kind `run_test` and the `probe`-kind `run_probe`. ScoutCoder
does not register a `test` capability or handler;
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
these six kinds.

The paths are always relative to the :current path map, which is the process
working directory (ENV['PWD']). In Scout you should always run inferences from
the base directory of the repository you want to work on, which should contain
at least a 'workflow.rb' file which is the entry point to load that workflow.
The name of that workflow should be the one you use when creating tasks or
helpers.

The project directories were the files get saved should not be included in the
path engine tools as should not be the file extension either. You have been
told about them exclusively so you can find them with the Workspace
tools, but you should forget about them when using the path engine. Paths
are RELATIVE to the kind root: no physical root prefixes
(`share/tasks/...`, `lib/<workflow>/...`, `share/python_tasks/...`,
`python/tasks/...`), no `.rb` or `.py` suffix, and
`entity_property` paths are nested `<entity>/<property>`. `.` is a root
selector only for enumeration surfaces (`path_list`, `run_test` suite
scope); it is not a readable path in `path_read`.

### Kind locations

Each of the five Ruby-file kinds except `probe` has two locations:
`tmp` (default) and
`project`. For the four source kinds (`task`, `entity`,
`entity_property`, `python_task`), `tmp` holds source drafts; only the
Ruby ones among them are loaded by LiveWorkflow (Python drafts are never
auto-loaded — registration is the workflow's own `python/tasks`
discovery, see [Wiring after promotion](#wiring-after-promotion-read-this-before-promoting)). For `test_file`, the locations
carry test resources that are never loaded automatically; it has THREE
locations (`tmp`, `project`, `python`). `path_promote` MOVES one resource from `tmp` to
`project`, where promoted source files are not loaded automatically (see
`Wiring after promotion` below). `probe` has ONE location only
(`tmp`, the default) and no promote: a probe is never promoted, only run.
Roots follow the current project — relative
Scout-path declarations are pinned to it once at registration, and every
operation authorizes against the pinned roots — and are declared per kind:

| kind | tmp root (drafts, default) | project root (promoted) | virtual path |
|---|---|---|---|
| `task` | `share/tasks` | `lib/<workflow>/tasks` | `greet_user` |
| `entity` | `share/entities` | `lib/<workflow>/entity` | `DemoWidget` |
| `entity_property` | `share/entity_properties` | `lib/<workflow>/entity` | `DemoWidget/tag_palette` |
| `python_task` | `share/python_tasks` | `python/tasks` | `my_task` |
| `test_file` | `share/test` | `test/<workflow>` (plus the `python` location `python/test`) | `task/greet_user` |
| `probe` | `share/probes` | (none — one-root kind, promote-less) | `motivating_outside_grant` |

Concrete physical locations for the example names: a task draft lives at
`share/tasks/greet_user.rb` and, after promotion, at
`lib/<workflow>/tasks/greet_user.rb`; an entity draft at
`share/entities/DemoWidget.rb` and, after promotion, at
`lib/<workflow>/entity/DemoWidget.rb` (a legacy snake draft keeps its
spelling on both sides, e.g. `share/entities/demo_widget.rb`); a property
draft at
`share/entity_properties/DemoWidget/tag_palette.rb` and, after promotion,
at `lib/<workflow>/entity/DemoWidget/tag_palette.rb`; a Python task draft
at `share/python_tasks/my_task.py` and, after promotion, at
`python/tasks/my_task.py`. Path Engine virtual
paths omit the physical root and the file suffix (`.rb` for the Ruby
kinds, `.py` for `python_task`).

`entity` and `entity_property` deliberately share the project root:
promoted entity files are flat `<entity>.rb` and promoted property files
are nested `<entity>/<property>.rb` below it. The `entity_property`
virtual path is nested for the same reason — one declarative promotion
destination covers the whole kind. A flat property path (`tag_palette.rb`)
is a validate error, not a second supported shape.

`test_file` is the odd one out: it manages TEST files, not source
drafts, and its roots cover unit and integration tests on both sides.
The virtual path's FIRST segment is the tier — `task`, `entity`,
`entity_property`, `python_task`, `helper`, or the marker `integration` —
and unit vs integration is decided purely by that first segment
(`integration/...` is an integration test; everything else is a unit
test). The complete
tier-spelling rules (which side carries the `test_` prefix, which
directories are renamed, the open-tier rule, and the resolved
inverse-mapping guarantee) are stated ONCE below with the advisory
pairing map in [validate](#validate).

The `python_task` tier is exceptional: it lives ONLY at the `python`
location (`python/test`, `Scout.python.test`) and maps DIRECTLY under
that root as `test_<name>.py` — the legacy scout-rig convention. The
tier directory is virtual-only there (no physical `python_task/`
subdirectory), and a FILE-shaped request for any OTHER tier at the
`python` location is rejected (`... hosts only the python_task tier`).
At the Ruby locations `python_task` is an ordinary open tier with the
generic `.rb` rules; the `python` location is that tier's home.

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
the kind's roots. `patch` is off for all six kinds (whole-file authored
sources), and no kind registers a `test` capability.

Capabilities are NOT identical across the six kinds: the four SOURCE
kinds (`task`, `entity`, `entity_property`, `python_task`) offer
validate + smoke + promote; `test_file` offers validate + promote
and **no smoke** (round-10 decision); `probe` offers validate (syntax
only) and a single custom operation, `run` — no smoke, no promote, no
second location. For `test_file`, `validate` is the static check and
`run_test` is the executing check — `run_test` reports `passed` and the
exit status separately, so the old "ran OK even if the tests failed"
smoke verdict was redundant and was removed. For `probe`, `validate` is
a pure AST parse that never executes the file; `run_probe` is the only
executing surface.

### validate

`path_validate` performs static shape checks on one file; it never
executes the target. Checks per kind:

- `task` — the source must parse and carry a `module <workflow>` wrapper
  (task files load into the <workflow> workflow module) plus a
  `task :name => :type do ... end` declaration. In the `tmp` location
  only, a missing `desc` is a warning, not an error (drafts carry their
  docs in a desc; promoted tasks move it to this README).
- `entity` — the source must parse, the top-level module must match
  `constant_name` of the file name: a CamelCase name must declare the
  identical module (`DemoWidget.rb` → `module DemoWidget`, `TF.rb` →
  `module TF`, with an optional leading `::`), and a legacy snake name
  must declare the Rule-B constant (`demo_widget.rb` → `module
  DemoWidget`). The module must
  contain an `extend Entity` or `extend EntityWorkflow` line. Declaring a
  second top-level module is a warning. Name-case errors follow the
  convention above: underscore CamelCase (`Demo_Widget.rb`) and other
  non-conforming names are hard errors; a legacy snake name is accepted
  with the warning naming both spellings; a constant collision with a
  sibling draft is a hard error.
- `entity_property` — the virtual path must be `<Type>/<property>`
  without a `.rb` suffix (a flat path is an error), the physical source must
  parse, the top-level module
  must match `constant_name` of the entity segment of the path
  (`DemoWidget/tag_palette.rb` → `module DemoWidget`; the legacy
  `demo_widget/tag_palette.rb` → `module DemoWidget` by Rule B), the
  entity segment follows the same name-case rules as the `entity` kind,
  the file must NOT carry an
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
- `python_task` — static checks only, in order: the file name must match
  `[a-z][a-z0-9_]*`; the source must be non-empty; it must pass
  `ast.parse` syntax validation (through a fresh `python -c` child that
  only parses — the source is never imported, and no `__pycache__` is
  ever created); and a static AST scan must find a `scout.task(...)`
  registration call (the scan is a cheap approximation — any module-level
  `scout.task(...)` call satisfies it; it does not bind names or run
  code). A missing module docstring is a WARNING at both locations
  (convention: Python tasks carry their docs in a module docstring;
  promoted files may move it to README.md per project convention).
- `probe` — syntax ONLY: the name must match `[a-z][a-z0-9_]*` and the
  source must pass a Ruby AST parse. Nothing else is checked, and the
  file is NEVER executed by `path_validate` — no side effects from
  validate, period (a probe can write files, so validating one must not
  run it). Execution happens exclusively through `run_probe`.

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
| `entity` | `share/test/entity/<Type>.rb` | `test/<workflow>/entity/test_<Type>.rb` |
| `entity_property` | `share/test/entity_property/<Type>/<Type>.<property>.rb` | `test/<workflow>/entity/<Type>/test_<property>.rb` |
| `helper` | `share/test/helper/<name>.rb` | `test/<workflow>/helpers/test_<name>.rb` |
| `integration` | `share/test/integration/<name>.rb` | `test/<workflow>/integration/test_<name>.rb` |
| `python_task` | (no tmp-side pair: the tier lives at the `python` location only) | `python/test/test_<name>.py` |

`<Type>` is the entity-type name in its OWN spelling — CamelCase
canonical (`DemoWidget`, `TF`), legacy snake keeps its snake spelling
(`demo_widget`); the map is parsing-free (virtual path == file
basename), so both spellings resolve identically.

**Spelling rule (stated once).** The share side carries no `test_`
prefix and keeps the tier spelling (`share/test/task/greet_user.rb`,
`share/test/integration/rt.rb`); the project side adds the `test_`
prefix to the FINAL FILENAME only, carries intermediate directories
through unchanged, and renames exactly one tier directory (`task` →
`tasks`). Concrete examples: `task/greet_user` →
`test/<workflow>/tasks/test_greet_user.rb`; `entity/DemoWidget` →
`test/<workflow>/entity/test_DemoWidget.rb` (legacy `entity/demo_widget`
→ `test/<workflow>/entity/test_demo_widget.rb`, own spelling);
`entity_property/DemoWidget/tag_palette`
→ `test/<workflow>/entity/DemoWidget/test_tag_palette.rb` (HIERARCHICAL,
the round-10 layout; the flattened `test_<entity>_<property>.rb`
spelling is gone: underscore-bearing names made it non-invertible);
note the TMP side of `entity_property` keeps its own
`<Type>/<Type>.<property>.rb` spelling, which differs from the
source-kind virtual path `<Type>/<property>`;
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
`test/<workflow>/test_path_kinds_roundtrip.rb`). The entity-tier
`<Type>` spellings (CamelCase canonical, legacy snake own-spelling) and
the parsing-free map (D2) are RATIFIED by the decision artifact
`reports/entity-case-convention-decision.md`. The `helper` project-side
spelling `test/<workflow>/helpers/test_<name>.rb` remains unratified: it
was derived by symmetry with the `share/test/helper/` draft side and has
no precedent in the checkout. `integration` is round 9's own convention
on both sides, with the same uniform `test_` prefix as every other tier.

`path_smoke` never runs a Scout job or inference. It exists on the four
SOURCE kinds only (`task`, `entity`, `entity_property`, `python_task`)
— the round-9 contract is "the resource can be
initialized/constructed/registered", never "it executes":
`task` loads the real workflow in a fresh process and CONSTRUCTS the
task's job with placeholder values for its required inputs only, never
executing it; `entity` asserts the module is defined and registered in
`Entity::MODULES`, with no dispatch; `entity_property` asserts the
property is registered on its module and that its accessor resolves to an
`UnboundMethod` — the property body is never dispatched; `python_task`
runs a fresh Ruby child that loads the real workflow, registers the draft
through `PythonWorkflow.load_directory`, and CONSTRUCTS the task's job
Step with placeholder values for its required inputs only (Python
requiredness: explicit `required` flag, or no default and not explicitly
optional) — the task body is never executed, and the metadata run never
imports the draft. `test_file` has NO smoke (removed in round 10): the
same evidence is produced by `run_test`, which actually executes the
tests in a fresh process and reports `passed`, `ran`, the exit status and
the exit classification separately — so a FAILING test is visible as a
failure, not as a passing "it ran" smoke.

### test_file run_test

The `test_file` kind carries one custom operation, `run_test`, exposed to
the model as its own `run_test` tool. Inputs: `kind` (always
`test_file`), `path` (the virtual test-file path; `.` selects the whole
suite), `scope` (`file`, `directory` or `suite`; default `file`), optional
`location` (`tmp`, the default, `project`, or `python`) and optional
`timeout_seconds` (per-file, default 120).

**Dispatch by extension.** A `.rb` test file runs in its own
fresh Ruby process that loads the `workflow.rb` of the project checkout
that OWNS the test file — so LiveWorkflow live-loads that checkout's
`share/` drafts — and then loads the test file (see
[Testing and execution](#testing-and-execution)). A `.py` test file (the `python_task` tier at
the `python` location) runs in its own fresh Python process:
`python3 -m unittest <module>` from the checkout owning the test tree,
with `PYTHONPATH` seeded from `ScoutPython.paths` (so `import scout`
resolves) and `PYTHONDONTWRITEBYTECODE=1` (no `__pycache__` is ever
created in the test tree). The standard-library runner serves; Scout-rig
0.2.6 ships no Python test runner of its own. The same process
discipline applies as for Ruby: process group, TERM, ten seconds of
grace, then KILL; per-file timeout 1..3600 seconds. Python exit-code
semantics map to the shared classes: 0 → `clean_pass`, 1 →
`assertion_failure` (the test RAN and failed — `passed` is false, `ran`
is true), 5 (`NO TESTS RAN`) or a zero-test discovery → `load_error`
(neither passed nor ran).

An explicit
`PATH_KIND_PROJECT_ROOT` constant (the regression-suite seam) overrides the
anchor, and the final fallback is the ScoutCoder checkout; the full
fallback chain is documented in `research/path-kind-contract-fixes.md`.
The per-file result reports `workflow_loaded`, the absolute path of the
`workflow.rb` the child loaded (Ruby) or the owning checkout (Python).
`scope: file` runs exactly one file;
`scope: directory` runs every test file under a path prefix;
`scope: suite` (conventionally with `path: "."`) discovers and runs every
test file in both Ruby locations plus the `python` location. Empty
discovery (no test files found) is an
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

### probe run_probe

The `probe` kind carries one custom operation, `run`, exposed to the
model as its own `run_probe` tool (the
workflow-level [`run_probe` task](#run_probe) wraps the same runner).
Inputs: `path` (the bare probe name, no `.rb` suffix, no
`share/probes/` prefix — single-probe scope only, no directory or suite
scope), optional `source` and optional `timeout_seconds` (integer
1..3600; default 120).

**Create-and-run semantics of `source`.** When `source` is given the
call does THREE things in one tool call: writes/overwrites the probe
file at `share/probes/<name>.rb`, syntax-checks the saved source with an
AST-only parse, and — only when the parse succeeds — executes it in the
fresh child. The result reports the three stages as INDEPENDENT
outcomes: `saved` (true/false plus the physical target), `syntax_ok`
(with `syntax_error` text when false) and the `execution` block. A
syntax failure means saved-but-not-executed; a runtime failure NEVER
reverts or deletes the saved source — the failure is reported
(`exit_class=raised`, the exception class and message, stderr, exit
status) with the file still on disk, so a probe can be fixed and rerun.
With `path` only, the existing saved probe is re-executed unchanged and
the run reports the same execution fields plus `executed`.

**No-autorun contract (settled, round 13).** The original round-12 ask was
auto-run: writing or editing a probe through the GENERIC path tools
would execute it. The engine contract (outcome C; DC-1/DC-2,
`tmp/notes/round12-engine-contract.md`) makes that impossible without
fighting the engine: generic `path_write` never consults a kind's
operation table, and a `path_edit` override is treated as a content
transform only, whose fixed result shape cannot carry an execution
report. So the design deliberately does NOT try — ratified in round 13
with a behavioral canary (`tmp/path_kinds/round13/no-autorun-evidence.md`)
and the two pin tests: the generic operations
`path_write`, `path_edit`, `path_read`, `path_list`, `path_move`,
`path_rename` and `path_delete` NEVER execute a probe — they are pure
file operations over the kind root — and create-and-run lives in the
`run` custom operation's `source` input, which is the channel custom
operations provide (payload returned verbatim, exactly like
`run_test`).

**Execution environment.** Each run spawns a fresh UNSANDBOXED Ruby
child. The child first preloads the owning checkout's `workflow.rb`
(the same anchor chain as `run_test`, including the
`PATH_KIND_PROJECT_ROOT` seam), then loads the probe file, so a probe
can use Scout constants and naturally exercises imports OUTSIDE the
Workspace bwrap grants — that reach is the motivating capability, not an
accident. Process discipline: process-group kill, TERM, ten seconds of
grace, then KILL; per-probe timeout 1..3600 seconds (default 120).
Failures are normalized into Scout exceptions or structured envelopes —
a non-Scout exception never escapes raw. The result reports
`workflow_loaded` (the checkout the child loaded), the runner spelling,
captured `stdout`/`stderr`, `exit_status`, `duration_seconds` and an
`exit_class` of `completed`, `raised` or `timeout`.

**Trust contract.** `run_probe` executes trusted Ruby with the caller's
authority, outside any OS sandbox, and the `probe` kind is meant for
ScoutCoder agents investigating the Scout framework itself — not for
general computation (use a workflow task for that) and not for
user-supplied untrusted code. Expose the kind (and the `run_probe`
task) only to agents that may already execute trusted Ruby in this
checkout.

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

The `probe` kind has NO promote: it is a one-root kind (its only
location is `tmp`, root `share/probes/`), there is no project
destination, and the engine accordingly installs no `path_promote`
support for it (a promote request is rejected with "Path kind probe
does not support promote").

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
- A promoted `python_task` file needs no `workflow.rb` line: the
  workflow's OWN `python/tasks` discovery (seeded from
  `Scout.python.tasks` across the path maps) picks it up on the next
  workflow load in a FRESH process. Until that discovery runs — in this
  process or any other — the promoted file is inert. `share/python_tasks`
  drafts are never auto-loaded either; smoke registers them explicitly
  through `PythonWorkflow.load_directory`.

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
- **`run_probe` executes UNSANDBOXED by design too** (round 12), with the
  same registration shape (`:full`, `authorization: :read`) and the same
  consequence: the kind declares `sandbox: true`, the probe path is
  authorized as a read, and the fresh child runs the probe with the
  caller's authority — deliberately outside the Workspace bwrap mounts,
  so a probe can reach engine checkouts and other files no sandboxed exec
  tool sees. This is the strongest authority ScoutCoder hands an agent:
  reserve the `probe` kind for agents already trusted to run arbitrary
  Ruby in this checkout.
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
- Sandboxing is on for all six kinds: `entity`, `entity_property`,
  `test_file` and `probe` declare `sandbox: true` explicitly,
  `python_task` and the `task` kind rely on the engine default, which is
  `true`. Roots are pinned to
  absolute paths at
  registration — the recommended spelling is a relative Scout path such as
  `Scout.share.tasks` or `Scout.lib['<workflow>'].tasks`, pinned against
  the current project — and every operation is authorized against those
  pinned roots before any callback runs.

### When to use which

Rule of thumb: the path tools address ONLY the six registered kinds; for
any other file — wiring, docs, data, config — use Workspace.

Create a draft from scratch with `path_write` on the right kind — the
kind root, the validation shape and (for the source kinds) registration
on workflow reload all come with the kind. `path_write` stores
whole-file content you author; the remaining tools read, edit, validate
and promote what is there (plus `run_test` on the `test_file` kind,
`run_probe` on the `probe` kind; smoke exists on the source kinds only).
For a probe you specifically want saved-and-run in one call, `run_probe`
with a `source` input does exactly that (see
[probe run_probe](#probe-run_probe)).

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
- Use `path_smoke` on `task`, `entity`, `entity_property`, or `python_task` to verify initialization/registration without executing domain behavior.
- Use `run_test` for a test file managed by the `test_file` kind, including directory or suite scopes.
- Use `run_probe` for an unsandboxed one-off Scout-framework investigation snippet managed by the `probe` kind.
- Use `run_task` to exercise a workflow task directly through the normal Scout job system. It is a behavior probe, not a substitute for an assertion-based test.
- Use `job_info` and `job_status` to inspect an existing job without re-running it.

### Authoring and running tests

Test code is ordinary trusted program code. The general test-file lifecycle is:

1. Create or inspect the source resource and use `path_validate`.
2. Write the paired test through `path_write` on kind `test_file`. Virtual examples are `task/greet_user`, `entity/DemoWidget`, `entity_property/DemoWidget/tag_palette`, `integration/round_trip`, and `python_task/my_task` (at `location: python`). Do not include the physical `share/test/`, `test/<workflow>/` or `python/test/` roots, or a `.rb`/`.py` suffix, in the virtual path.
3. Run the test with `run_test` at `scope: file`. Widen to `directory` or `suite` only when a broader check is useful. A zero-file discovery is an error, not a passing empty suite.
4. For source kinds, separately use `path_smoke` when load/registration needs verification. A passing smoke check does not prove behavior.
5. If the source and test should be permanent, promote each resource separately with `path_promote`. The engine moves one resource per operation; it does not move its paired test for you.
6. After promoted source is wired into `workflow.rb`, re-run the test or relevant suite from a fresh process.

The paired-test tier conventions (`share/test/task/<name>.rb` on the
tmp side, `test/<workflow>/tasks/test_<file>.rb` for shipped task code
under `lib/<workflow>/tasks/`) remain the naming rule for a task's test;
the `test_file` kind and `run_test` are the authoring and execution
surface for both sides.

A test file for the generic runner uses the Test::Unit shape:

```ruby
require 'test/unit'

class MyTaskTest < Test::Unit::TestCase
  def test_example
    assert_equal 2, 1 + 1
  end
end
```

A Python test file (the `python_task` tier, written as
`python_task/<name>` at `location: python` and stored physically as
`python/test/test_<name>.py`) uses the unittest shape:

```python
import unittest

class TestMyTask(unittest.TestCase):
    def test_example(self):
        self.assertEqual(2, 1 + 1)
```

`run_test` dispatches on the file extension: `.rb` files run as Ruby
Test::Unit (fresh Ruby process loading the owning checkout's
`workflow.rb`), `.py` files as Python unittest (`python3 -m unittest`,
`PYTHONPATH` from `ScoutPython.paths`, no `__pycache__`). Exit-code
semantics: Python 0 → `clean_pass`, 1 → `assertion_failure`, 5
(`NO TESTS RAN`) or zero discovered tests → `load_error`; `passed` and
`ran` stay separate booleans for both languages. `run_test` mechanics
(fresh per-file process, anchor contract, exit classification, `passed`
vs `ran`) are documented once in
[`### test_file run_test`](#test_file-run_test) and the
[`## run_test`](#run_test) task entry. Both specialized and general test
runners start fresh processes, but Scout job/Step results are persistent
and are not automatically cleared; see
[Fresh process versus fresh result](#fresh-process-versus-fresh-result).

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

## run_test
Run test files through the `test_file` path kind

Inputs: `path` (the `test_file` virtual path; `.` for the whole suite),
`scope` (`file`, `directory` or `suite`; optional, default `file`),
optional `location` (`tmp`, `project` or `python`, default `tmp`), and
optional `timeout_seconds` (integer 1..3600; default 120 for `file` and
`directory`, 300 for `suite`). The target is resolved through the agent's
`test_file` kind, then dispatched according to scope. Each selected `.rb`
file runs in its own
fresh Ruby process, which loads the `workflow.rb` of the project checkout
that owns the test file (see
[`### test_file run_test`](#test_file-run_test) for the anchor contract)
and then the test file, with `lib/` on the load path. Each selected `.py`
file runs in its own fresh Python process (`python3 -m unittest`), as
described in [`### test_file run_test`](#test_file-run_test).

**Execution is unsandboxed.** The test path is authorized as a read resource,
but the child process runs trusted test code with the caller's authority. See
[Development doctrine and tool selection](#development-doctrine-and-tool-selection)
and [Trust boundaries](#trust-boundaries). Discovering zero test files is a
`ParameterException`, not a passing empty suite. The result reports per-file
exit status/classification (`clean_pass`, `assertion_failure`, `load_error`,
`timeout`), test/assertion counts, captured output, and distinct `passed`
and `ran` fields. Persistent Scout job caches are not cleared automatically.

## run_probe
Run one probe through the `probe` path kind

Inputs: `path` (the bare probe name; single-probe scope only), optional
`source` (complete probe Ruby source; when given the probe is written,
syntax-checked and executed in one call) and optional `timeout_seconds`
(integer 1..3600, default 120). The target is resolved through the
`probe` kind, then dispatched. See
[`### probe run_probe`](#probe-run_probe) for the create-and-run
semantics, the independent saved/syntax/execution outcomes, and the
execution environment.

**Execution is unsandboxed** and runs trusted code with the caller's
authority — deliberately outside Workspace sandbox grants, so a probe can
read engine checkouts and any other file the caller can reach. It is
ScoutCoder-only, for investigating the Scout framework. A runtime failure
is reported (`exit_class=raised`, exception class and message, stderr,
exit status) and NEVER reverts or deletes the saved source; a syntax
failure reports `syntax_ok: false` and skips execution entirely.
`workflow_loaded` records the checkout whose `workflow.rb` the child
preloaded.

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

Input propagation (scout-gear `doc/user/BuildingWorkflows.md` § dependencies):
unset dependency inputs propagate recursively — a blockless `dep` forwards
every caller input the dependency task declares, whether or not the parent
mentions it — and those recursive inputs are exactly what agent-exposed
workflow tools present (the tool schema is built from `task_info[:inputs]` =
`rec_inputs(name).uniq`). Re-declaring a dependency input on the parent is
free and merely lets the parent block see the value.

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
