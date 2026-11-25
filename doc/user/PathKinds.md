# Path kinds operational guide

ScoutCoder registers six agent path kinds — `task`, `entity`, `entity_property`,
`python_task`, `test_file`, `probe` — exposing the authoring surfaces of the
current project's workflow as virtual filesystems operated with the generic
`path_*` tools. For registration and capability details, see
[PathKindsInternals.md](../developer/PathKindsInternals.md).

This guide covers addressing, validation, smoke checks, running tests and
probes, promotion, loader wiring, and making authored capabilities available
to their consumers.

## Virtual path rules

Start the inference bout from the root of the project checkout you intend to
work on. The checkout should contain `workflow.rb`, the workflow entrypoint.
Use the actual name of the owning workflow when declaring tasks or helpers.
Project paths are resolved through Scout's `:current` path map; path-kind
roots are pinned to absolute paths at registration.

Virtual paths are relative to the selected kind's root. Do not include the
physical root prefix or the `.rb` or `.py` extension. For example, use
`greet_user`, not `share/tasks/greet_user.rb`. Entity-property paths are nested
as `<Type>/<property>`. The physical paths below are for locating files with
Workspace, not for addressing them with path tools.

`.` selects a root for enumeration (`path_list`) or a test suite (`path_run`);
it is not a readable file path for `path_read`.

| Kind | `tmp` root (drafts, default) | `project` root (promoted) | Virtual path |
|---|---|---|---|
| `task` | `share/tasks` | `lib/<workflow>/tasks` | `greet_user` |
| `entity` | `share/entities` | `lib/<workflow>/entity` | `DemoWidget` |
| `entity_property` | `share/entity_properties` | `lib/<workflow>/entity` | `DemoWidget/tag_palette` |
| `python_task` | `share/python_tasks` | `python/tasks` | `my_task` |
| `test_file` | `share/test` | `test/<workflow>` (also `python/test` at the `python` location) | `task/greet_user` |
| `probe` | `share/probes` | None | `motivating_outside_grant` |

## Validation

`path_validate` checks the static shape of one file. It never executes the
source. Validation is not a substitute for loading, smoke-checking or testing
the implementation.

- `task`: the source must parse, contain a `module <workflow>` wrapper and
  declare a task using `task :name => :type do ... end`. At the `tmp` location,
  a missing `desc` is a warning. Draft tasks carry their documentation in a
  `desc`; promoted tasks move it to the README.
- `entity`: use the full type name as one path component, for example
  `DemoWidget` or `AGS::TF`. The source must parse and declare the matching
  module with `extend Entity` or `extend EntityWorkflow` inside it. Nested
  module blocks and qualified declarations are accepted. An additional
  top-level module produces a warning. An unqualified snake_case draft such
  as `demo_widget` maps to `DemoWidget` and produces a warning. Two drafts
  mapping to the same constant produce a validation error.
- `entity_property`: use `<Type>/<property>`, for example `AGS::TF/label`.
  The file reopens the entity module and declares the property inside it.
  The entity definition owns the `extend` call. A different declared
  property name produces a warning. A typeless `property :plain do`
  dispatches as `:both`. See [AuthoringEntities.md](AuthoringEntities.md) for
  complete examples.
- `test_file`: Ruby files must pass syntax validation. The recommended shape
  requires the test harness and declares at least one `Test::Unit::TestCase`
  subclass. Harness, test-class and filename/location conventions are
  advisory warnings, not hard validation requirements. This includes a
  project-side file lacking the `test_` prefix or a tmp-side file carrying
  it. The Test::Unit convention is the shape the runner uses to report test
  and assertion counts.
- `python_task`: the filename must match `[a-z][a-z0-9_]*`, the source must
  be non-empty, and it must pass `ast.parse` in a fresh Python child. A
  static AST scan must find a module-level `scout.task(...)` registration
  call; this check neither binds names nor executes code. Validation does
  not import the source or create `__pycache__`. A missing module docstring
  is a warning at both locations. Promoted files may move documentation to
  the README according to project convention.
- `probe`: the name must match `[a-z][a-z0-9_]*` and the Ruby source must pass
  an AST parse. Nothing else is checked. Probes can have side effects, so
  validation never executes them. Execute them explicitly through `path_run`
  with `kind: "probe"`.

## Paired-test convention

Tests are ordinary `test_file` resources authored with `path_write` and
executed through `path_run(kind: "test_file", ...)`. Pairing a source file
with its test is a naming convention, not an automatic relocation operation.
`path_promote` moves exactly one resource. Promote the test separately.

| Source or test tier | Draft test | Project test |
|---|---|---|
| `task` | `share/test/task/<name>.rb` | `test/<workflow>/tasks/test_<name>.rb` |
| `entity` | `share/test/entity/<Type>.rb` | `test/<workflow>/entity/test_<Type>.rb` |
| `entity_property` | `share/test/entity_property/<Type>/<Type>.<property>.rb` | `test/<workflow>/entity/<Type>/test_<property>.rb` |
| `helper` | `share/test/helper/<name>.rb` | `test/<workflow>/helpers/test_<name>.rb` |
| `integration` | `share/test/integration/<name>.rb` | `test/<workflow>/integration/test_<name>.rb` |
| `python_task` | None | `python/test/test_<name>.py` (`python` location) |

The table describes test tiers; `helper` and `integration` are not additional
path kinds. Author helper source files with Workspace.

Use the entity type's own spelling in the test path, preferably its canonical
CamelCase or qualified name. If an existing test uses a snake_case spelling,
address that spelling as stored; the path mapping does not resolve Ruby
constant aliases.

The share-side filename has no `test_` prefix. The project side adds `test_`
to the final filename and applies the tier-specific directory mapping shown
above. Use the following virtual paths at either location:

| Virtual `test_file` path | Project destination |
|---|---|
| `task/greet_user` | `test/<workflow>/tasks/test_greet_user.rb` |
| `entity/DemoWidget` | `test/<workflow>/entity/test_DemoWidget.rb` |
| `entity_property/DemoWidget/tag_palette` | `test/<workflow>/entity/DemoWidget/test_tag_palette.rb` |
| `integration/rt` | `test/<workflow>/integration/test_rt.rb` |

For entity-property tests, the draft filename is `<Type>.<property>.rb`, but
the virtual path remains `entity_property/<Type>/<property>`. Unknown test
tiers resolve under a directory of the same name beneath the selected test
root. Use recognized tiers where applicable.

Mirror the tested source's logical path for unit tests. This is a convention,
not a hard constraint. Integration tests need not correspond to a single
source file. See [PathKindsInternals.md](../developer/PathKindsInternals.md)
for the detailed tier mapping.

## Running tests and probes

`probe` and `test_file` are the two runnable kinds. Both use the same
`path_run` operation. The `kind` enum contains only runnable kinds registered
for the agent.

The common inputs are `kind`, `path`, `location` and optional
`timeout_seconds` (1–3600; otherwise the runner's default). `source` is
specific to probes; `scope` is specific to tests. Each kind rejects the
other kind's option before execution.

### Examples

Create, validate and execute a probe in one call:

```
path_run(kind: "probe", path: "hello_probe", source: "puts 'hello'")
```

Re-run the saved probe unchanged:

```
path_run(kind: "probe", path: "hello_probe")
```

Run an individual test or the project-side suite:

```
path_run(kind: "test_file", path: "entity_property/Gene/onset")
path_run(kind: "test_file", path: ".", scope: "suite", location: "project")
```

### `kind: "test_file"`

`path` is the virtual test path, with `.` available for suite selection.
`scope` controls discovery: `file` (default) runs one file, `directory` runs
files below a path prefix, and `suite` selects the suite. Test locations are
`tmp` (default), `project` and `python`; use `location` to select the side
when needed. Suite discovery supports all three locations. The optional
`timeout_seconds` is per file (default 120 s; 300 s for suite scope).

Ruby tests run in a fresh Ruby process loading the owning checkout's
`workflow.rb`. Python tests run in a fresh Python process using
`python3 -m unittest`, with `PYTHONPATH` from `ScoutPython.paths` and without
creating `__pycache__`.

Per-file results report exit status, classification (`clean_pass`,
`assertion_failure`, `load_error`, `timeout`), test and assertion counts,
captured output, and separate `passed` and `ran` booleans. Zero discovered
test files is an error, not a passing empty suite.

See [Testing.md](../developer/Testing.md) for the runner's mechanics.

### `kind: "probe"`

A probe path is a bare name, without `.rb` or `share/probes/`. Only
single-probe execution is supported.

With `source`, `path_run` writes or overwrites the probe, validates its Ruby
syntax, and executes it in a fresh unsandboxed child if validation succeeds.
The result reports `saved`, `syntax_ok` and `execution` separately. A runtime
failure does not delete the saved source; a syntax failure skips execution.
With `path` alone, the existing source is re-executed unchanged.

Probes run trusted Ruby with the caller's authority, outside the Workspace
OS sandbox. Reserve them for investigations that require native Scout
execution. See [Testing.md](../developer/Testing.md).

## Promotion

`path_promote` moves one resource from `tmp` to its declared `project` root.
The engine authorizes both endpoints and refuses to overwrite an existing
destination unless `overwrite: true` is supplied. A refused promotion leaves
the source intact.

Promotion moves only the selected resource. Promote a source and its test
separately. The agent coordinates related moves and loader wiring.

The `probe` kind has only a `tmp` location and does not support promotion.

### Promotion result and reload behaviour

A completed move reports `promoted: true`, `destination`, `promotion_target`
and `promotion_source_target`. The reload outcome is reported separately
through `promotion_status`:

- `succeeded`: the automatic workflow reload completed
  (`post_move: "workflow_reload"`). The compact `reload` report contains
  `{ok: true, root, purged, mode}`; `purged` is the count of purged feature
  entries. The full list and entrypoint are in the `reload_workflow` report.
  This confirms the reload at that point, in the executing process. It does
  not confirm registration of source that has not yet been wired, or
  availability in another process.
- `reload_failed`: the move completed, but the automatic reload failed.
  `reload` reports `{ok: false, error, root}`, with the original diagnostic.
  If no owning `workflow.rb` can be found, the diagnostic is returned
  without a `root` key. These outcomes are reported without an exception
  envelope. Fix the cause and reload again; do not retry the completed move.
- `deferred`: the move completed and reload was explicitly deferred.

The hook raises only when it cannot construct a report at all (no
`promotion_target` in the promotion result).

### Related promotions: defer the reload

For related source files, pass `defer_reload: true` to each promotion and
reload once after all files have been moved and wired. This avoids evaluating
a partially wired set of definitions, particularly when promoting an entity
and its properties together.

Without `defer_reload`, each promotion triggers its automatic reload. A
subsequent loader edit still requires another reload.

The `scoutcoder-path-kinds-lifecycle` skill provides the step-by-step
procedure, including fresh-process verification.

## Wiring after promotion

Promotion is a file move, not registration. Ensure the owning workflow's
loader includes the promoted source.

- **Ruby task:** add or confirm an appropriate require in `workflow.rb` or
  its loader chain. For example:

  ```ruby
  require_relative 'lib/<workflow>/tasks/greet_user'
  ```

- **Entity or property:** ensure the loader includes the entity definition
  before its property files. LiveWorkflow loads `share/` drafts; do not
  assume that it also discovers promoted files under
  `lib/<workflow>/entity/`. Follow the checkout's existing loader convention,
  adding requires where necessary.
- **Python task:** no individual Ruby require is needed when the owning
  workflow's `python/tasks` discovery is configured. The promoted task is
  registered when discovery runs, including on a fresh workflow load.
  Drafts under `share/python_tasks` are not automatically registered;
  smoke-checking registers them explicitly through
  `PythonWorkflow.load_directory`.

Path tools do not edit `workflow.rb` for you. Use Workspace for loader and
other ordinary source edits. For promoted Ruby tasks, move the draft `desc`
to the README's `# Tasks` section using `document_task` (see
[Testing.md](Testing.md), “Documentation during promotion”).

### Reload the owning workflow

After the final promotion and loader edit, call `reload_workflow` with the
absolute path of the checkout containing the edited `workflow.rb`. This
applies even if a single promotion returned `promotion_status: succeeded`:
the automatic reload preceded any subsequent wiring edits. For related
promotions with `defer_reload: true`, reload once after wiring. Reload after
editing existing loaded Ruby definitions as well.

For example, invoke the exported ScoutCoder tool directly:

```
reload_workflow(root: "/absolute/path/to/AGS")
```

Check `ok`, the reported `root`, `entrypoint` and `workflow`, and inspect
any reload diagnostic. A successful report establishes that the reload
completed in the process executing the operation. It does not establish
that a particular exported task or property was registered; check that
separately.

### Verify the implementation and make it available to consumers

Scout-AI delegates agents in isolated processes. Source files are shared
with agents that have appropriate access, but loaded workflow definitions
and entity registrations are process-local. Reloading a workflow in a
ScoutCoder delegation does not reload it in the requesting agent.

There are three separate operations:

| Operation | Effect |
|---|---|
| `reload_workflow` | Updates loaded definitions in the executing runtime. |
| Tool preparation | Constructs callable tools and input schemas from the agent's tooling declarations and loaded workflows. |
| Job refresh | Recomputes persisted computational results instead of reusing the cache. |

**As the author:** verify that the edited checkout loads and that the new or
changed capability works. Use a fresh-process test and a representative
native invocation where appropriate. Report the owning checkout's absolute
root, the task name or qualified entity type and property, and a small
verified example. State whether the task was exported if it is intended as
an agent tool. Do not claim availability in another agent's runtime solely
on the basis of local verification.

**As the consumer or coordinating agent:** after receiving the development
result, reload the owning workflow in your own execution process before
using the new definitions or delegating work that requires them. Agents
that need this capability can be given the following declaration in their
`start_chat`:

```
tool: ScoutCoder reload_workflow
```

Call `reload_workflow` directly with the reported checkout root. The tool
must be exec-exported so it runs inline in the invoking agent's runtime,
not in a separate job fork. This is a prerequisite for the direct reload
procedure.

- **Entities and properties:** Semantics exposes stable discovery and
  dispatch tools. After reloading the owning workflow, use `list_entities`
  to find the type and property, then invoke `entity_property` or
  `entity_list_property` on a known identifier or collection. New entity
  definitions do not require new Semantics tool definitions.
- **Exported tasks:** reloading registers the task in the runtime, but does
  not automatically reconstruct the callable tool set of an ongoing
  inference bout. A subsequent delegated agent inherits the reloaded runtime
  and can obtain the new task when its tooling is prepared, provided its
  declarations expose that workflow or task. To use the new task in the
  current agent, prepare its tooling again against the updated workflow in
  a subsequent bout. Existing tools may retain earlier schemas or workflow
  references; verify their behaviour after a reload when relevant.

A reload is local to the invoking process and does not update its parent,
other already-running agents, or unrelated runtimes. A new conversation or
fork from a stale runtime does not by itself guarantee current definitions.

Reloading also does not invalidate cached job results. Use
`refresh: "refresh"` or `refresh: "deep_refresh"` where appropriate on
cacheable calls whose implementation or dependencies have changed. Tests
and probes run in fresh processes; success there is evidence about the
checkout, not about the loaded state of an ongoing agent.

If consumer access is unavailable, hand back the reload root and verified
invocation so the consumer can perform its own check. Report consumer
availability as unverified until that check succeeds.

## Trust boundaries

- `path_run` executes trusted tests and probes in fresh unsandboxed child
  processes with the caller's authority. Path authorization authorizes the
  kind path as a read; it is not an OS sandbox for the executed code. Expose
  these operations only to agents authorized to execute such code.
- `reload_workflow` loads executable Ruby source. Expose it only to agents
  authorized to load the relevant project workflows. A narrow tool
  declaration does not remove the need for checkout authorization.
- Path kinds do not relocate files outside their roots. The agent coordinates
  changes involving multiple resources.
- Entity definitions must load before their properties; missing entity
  modules cause property loading to fail.
- Roots are pinned to absolute paths at registration. Operations are
  authorized against the pinned roots before callbacks run.

See [PathKindsInternals.md](../developer/PathKindsInternals.md) for the
registration shapes and trust model.

## When to use path tools or Workspace

Use path tools for the six registered kinds. Use Workspace for everything
else, including shared library helpers, loader wiring, documentation, data
and configuration.

`path_write` stores the source you supply at the selected kind's root.
The remaining path tools read, edit, validate, smoke-check and promote
resources according to their kind's contract. `path_run` is for tests and
probes; smoke checks are for source kinds only.

For example, author a task with `path_write kind=task path=greet_user`.
The engine chooses `share/tasks/greet_user.rb`; `path_validate` checks its
shape, and loading or smoke-checking establishes registration. Writing the
same physical file through Workspace does not perform the path-kind checks.

To wire the promoted task, use Workspace on the actual loader file. There
is no separate path kind for loader edits or ordinary helper files.

## Lifecycle

1. Use `path_write` to create the draft at `tmp`.
2. Use `path_validate` to check its shape.
3. Author the paired `test_file` where appropriate and run it with
   `path_run(kind: "test_file", ...)` in a fresh process. For Python tests,
   use the `python` location.
4. Use `path_smoke` for source kinds to confirm initialization and
   registration. Test files and probes use `path_run` rather than smoke.
5. Promote the source and its test separately when ready. For a related
   group of source promotions, pass `defer_reload: true` to each.
6. Complete or verify loader wiring. Reload the owning checkout and verify
   the implementation with a representative invocation and appropriate
   fresh-process tests.
7. If working on behalf of another agent, report the checkout root and
   verified capability. The consumer or coordinating agent reloads in its
   own runtime and checks discovery or execution. Newly exported tasks
   require tooling preparation against the reloaded workflow.
