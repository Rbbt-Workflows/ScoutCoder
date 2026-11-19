# Path kinds operational guide

ScoutCoder registers six agent path kinds — `task`, `entity`,
`entity_property`, `python_task`, `test_file`, `probe` — exposing the
authoring surfaces of the current project's own workflow as virtual
filesystems operated with the generic `path_*` tools (registration and
capability details:
[doc/developer/PathKindsInternals.md](../developer/PathKindsInternals.md)).
This page is the operational how-to: addressing paths, validating,
smoke-checking, running tests and probes through the single `path_run`
operation, promoting, and wiring after promotion.

## Virtual path rules

The paths are always relative to the :current path map, which is the
process working directory (ENV['PWD']). In Scout you should always run
inferences from the base directory of the repository you want to work on,
which should contain at least a 'workflow.rb' file which is the entry point
to load that workflow. The name of that workflow should be the one you use
when creating tasks or helpers.

The project directories were the files get saved should not be included in
the path engine tools as should not be the file extension either. You have
been told about them exclusively so you can find them with the Workspace
tools, but you should forget about them when using the path engine. Paths
are RELATIVE to the kind root: no physical root prefixes
(`share/tasks/...`, `lib/<workflow>/...`, `share/python_tasks/...`,
`python/tasks/...`), no `.rb` or `.py` suffix, and `entity_property` paths
are nested `<entity>/<property>`. `.` is a root selector only for
enumeration surfaces (`path_list`, `path_run` suite scope); it is not a
readable path in `path_read`.

The roots per kind (tmp = drafts; project = promoted):

| kind | tmp root (drafts, default) | project root (promoted) | virtual path |
|---|---|---|---|
| `task` | `share/tasks` | `lib/<workflow>/tasks` | `greet_user` |
| `entity` | `share/entities` | `lib/<workflow>/entity` | `DemoWidget` |
| `entity_property` | `share/entity_properties` | `lib/<workflow>/entity` | `DemoWidget/tag_palette` |
| `python_task` | `share/python_tasks` | `python/tasks` | `my_task` |
| `test_file` | `share/test` | `test/<workflow>` (plus the `python` location `python/test`) | `task/greet_user` |
| `probe` | `share/probes` | (none — one-root kind, promote-less) | `motivating_outside_grant` |

## validate

`path_validate` performs static shape checks on one file; it never executes
the target. Checks per kind:

- `task` — the source must parse and carry a `module <workflow>` wrapper
  (task files load into the <workflow> workflow module) plus a
  `task :name => :type do ... end` declaration. In the `tmp` location only,
  a missing `desc` is a warning, not an error (drafts carry their docs in a
  desc; promoted tasks move it to the README).
- `entity` — the source must parse, the top-level module must match
  `constant_name` of the file name: a CamelCase name must declare the
  identical module (`DemoWidget.rb` → `module DemoWidget`, `TF.rb` →
  `module TF`, with an optional leading `::`), and a legacy snake name must
  declare the Rule-B constant (`demo_widget.rb` → `module DemoWidget`). The
  module must contain an `extend Entity` or `extend EntityWorkflow` line.
  Declaring a second top-level module is a warning. Name-case errors follow
  the convention in
  [AuthoringEntities.md](AuthoringEntities.md): underscore CamelCase
  (`Demo_Widget.rb`) and other non-conforming names are hard errors; a
  legacy snake name is accepted with the warning naming both spellings; a
  constant collision with a sibling draft is a hard error.
- `entity_property` — the virtual path must be `<Type>/<property>` without
  a `.rb` suffix (a flat path is an error), the physical source must parse,
  the top-level module must match `constant_name` of the entity segment of
  the path (`DemoWidget/tag_palette.rb` → `module DemoWidget`; the legacy
  `demo_widget/tag_palette.rb` → `module DemoWidget` by Rule B), the entity
  segment follows the same name-case rules as the `entity` kind, the file
  must NOT carry an `extend` line (the entity file owns the extend), and it
  must declare `property :name => :type do ... end`; a declared property
  name that differs from the path's property segment is a warning. A
  typeless `property :plain do` is valid and dispatches as `:both`.
- `test_file` — the target must parse as Ruby, must require the test
  harness and declare at least one `<...> < Test::Unit::TestCase` subclass;
  a file that only requires the harness (no test class) validates with a
  warning, and the `test_` prefix/location conventions are WARNINGS, not
  errors (a project-side file lacking the `test_` prefix or a tmp-side file
  carrying it is reported, never rejected). The Test::Unit convention
  itself is advisory too: it is the shape the runner reports counts from,
  and what the regression suite pins, but `validate`'s reliable check is
  Ruby SYNTAX (AST parse), with the harness/class/prefix checks layered on
  top as warnings.
- `python_task` — static checks only, in order: the file name must match
  `[a-z][a-z0-9_]*`; the source must be non-empty; it must pass
  `ast.parse` syntax validation (through a fresh `python -c` child that
  only parses — the source is never imported, and no `__pycache__` is ever
  created); and a static AST scan must find a `scout.task(...)`
  registration call (the scan is a cheap approximation — any module-level
  `scout.task(...)` call satisfies it; it does not bind names or run code).
  A missing module docstring is a WARNING at both locations (convention:
  Python tasks carry their docs in a module docstring; promoted files may
  move it to README.md per project convention).
- `probe` — syntax ONLY: the name must match `[a-z][a-z0-9_]*` and the
  source must pass a Ruby AST parse. Nothing else is checked, and the file
  is NEVER executed by `path_validate` — no side effects from validate,
  period (a probe can write files, so validating one must not run it).
  Execution happens exclusively through `path_run` with
  `kind: "probe"`.

## Paired-test convention

Test files are ordinary `test_file` resources authored with `path_write`;
execute them explicitly through the `path_run` operation with
`kind: "test_file"`.
The association between a source draft and its paired test is an advisory
naming convention: the Path Engine promotes exactly ONE resource per
`path_promote` call, and the source kinds do not register paired-test
relocation. Promote the test itself through the `test_file` kind when you
want it on the project side. The advisory pairing map is:

| kind | tmp paired test | project paired test |
|---|---|---|
| `task` | `share/test/task/<name>.rb` | `test/<workflow>/tasks/test_<name>.rb` |
| `entity` | `share/test/entity/<Type>.rb` | `test/<workflow>/entity/test_<Type>.rb` |
| `entity_property` | `share/test/entity_property/<Type>/<Type>.<property>.rb` | `test/<workflow>/entity/<Type>/test_<property>.rb` |
| `helper` | `share/test/helper/<name>.rb` | `test/<workflow>/helpers/test_<name>.rb` |
| `integration` | `share/test/integration/<name>.rb` | `test/<workflow>/integration/test_<name>.rb` |
| `python_task` | (no tmp-side pair: the tier lives at the `python` location only) | `python/test/test_<name>.py` |

`<Type>` is the entity-type name in its OWN spelling — CamelCase canonical
(`DemoWidget`, `TF`), legacy snake keeps its snake spelling (`demo_widget`);
the map is parsing-free (virtual path == file basename), so both spellings
resolve identically.

**Spelling rule (stated once).** The share side carries no `test_` prefix
and keeps the tier spelling (`share/test/task/greet_user.rb`,
`share/test/integration/rt.rb`); the project side adds the `test_` prefix
to the FINAL FILENAME only, carries intermediate directories through
unchanged, and renames exactly one tier directory (`task` → `tasks`).
Concrete examples: `task/greet_user` → `test/<workflow>/tasks/test_greet_user.rb`;
`entity/DemoWidget` → `test/<workflow>/entity/test_DemoWidget.rb` (legacy
`entity/demo_widget` → `test/<workflow>/entity/test_demo_widget.rb`, own
spelling); `entity_property/DemoWidget/tag_palette` →
`test/<workflow>/entity/DemoWidget/test_tag_palette.rb` (HIERARCHICAL, the
round-10 layout; the flattened `test_<entity>_<property>.rb` spelling is
gone: underscore-bearing names made it non-invertible); note the TMP side
of `entity_property` keeps its own `<Type>/<Type>.<property>.rb` spelling,
which differs from the source-kind virtual path `<Type>/<property>`;
`integration/rt` → `test/<workflow>/integration/test_rt.rb`. The tier list
is open on the tmp side: any first segment other than `entity_property`
resolves under a same-named directory below `share/test` (unknown tiers
included); on the project side the known tiers are rewritten, and an
unknown first segment resolves under a same-named directory below
`test/<workflow>`. The documented tiers are the recognized ones.

**Unit-test path convention is doctrine, not enforcement.** Mirroring the
tested file's path under the test tree is enforced only through this
documentation and advisory checks — nothing hard-rejects a test that lives
elsewhere inside the test tree. Integration tests pair with no single
source file and are free-form within the test tree. Ratification status of
the map itself: see
[doc/developer/PathKindsInternals.md](../developer/PathKindsInternals.md)
§ "Tier-mapping convention status".

## path_run: one operation, two runnable kinds

The `probe` and `test_file` kinds are the two runnable kinds: executing
them is a custom operation named `path_run`, exposed to the model as ONE
`path_run` tool whose `kind` enum lists exactly the runnable kinds
registered for the agent (`probe`, `test_file` when both are loaded; a
single-kind configuration advertises only that kind). The two kinds
declare an identical, kind-neutral parameter contract, so one signature
serves both.

Inputs: `kind` (`\"probe\"` or `\"test_file\"`), `path` (the virtual path),
`location` (the kind's storage location), `timeout_seconds` (optional,
1..3600 — when omitted the runner's own default stays in effect), plus
one kind-specific option: `source` (probe only) and `scope` (test_file
only). Each kind REJECTS the other kind's option before anything
executes, so a caller can never believe a supplied `source` or `scope`
took effect on the wrong kind.

### Copyable examples

(i) Create-and-run a probe in one call (write, syntax-check, execute):

```
path_run(kind: "probe", path: "hello_probe", source: "puts 'hello'")
```

(ii) Re-run a probe already saved under `share/probes/`:

```
path_run(kind: "probe", path: "hello_probe")
```

(iii) Run a paired test file (and the whole suite):

```
path_run(kind: "test_file", path: "entity_property/Gene/onset")
path_run(kind: "test_file", path: ".", scope: "suite", location: "project")
```

### kind=test_file (test files)

`path` is the virtual test-file path (`.` selects the whole suite) and
`scope` selects how many files run: `file` (default) runs exactly one,
`directory` runs every test file under a path prefix, `suite` discovers
and runs every test file in all locations (tmp, project and python).
Optional `location` picks the side (`tmp` default, `project`, `python`),
and optional `timeout_seconds` is per file (default 120 s; 300 s for
suite scope).

`.rb` test files run in a fresh Ruby process loading the owning checkout's
`workflow.rb`; `.py` test files run in a fresh Python process
(`python3 -m unittest`, `PYTHONPATH` from `ScoutPython.paths`, no
`__pycache__`). Per-file results report the exit status, a classification
(`clean_pass`, `assertion_failure`, `load_error`, `timeout`), test and
assertion counts, captured output, and separate `passed` / `ran` booleans.
Zero discovered files is an error, not a passing empty suite. Full
mechanics (anchor chain, process discipline, exit-code mapping) are in
[doc/developer/Testing.md](../developer/Testing.md).

### kind=probe (unsandboxed probes)

`path` is the bare probe name (no `.rb` suffix, no `share/probes/`
prefix — single-probe scope only; there is no directory or suite scope).
With `source`, one call writes/overwrites the probe file, syntax-checks
it (AST-only) and — only when the parse succeeds — executes it in a
fresh unsandboxed child; the result reports `saved`, `syntax_ok` and the
`execution` block as independent outcomes. A runtime failure never
deletes the saved source; a syntax failure skips execution entirely.
With `path` only, the existing saved probe is re-executed unchanged.
Probes run trusted Ruby with the caller's authority, outside any OS
sandbox — reserve them for Scout-framework investigations. Full
mechanics: [doc/developer/Testing.md](../developer/Testing.md).

## promote

`path_promote` moves ONE resource from `tmp` to `project`. The destination
is declarative — always the kind's `project` root. The engine authorizes
both endpoints, refuses to overwrite an existing destination unless you
pass `overwrite: true`, and performs the move itself; the refusal happens
before the move, so a refused promotion leaves the source file intact. No
ScoutCoder kind registers a `promotion_post_move` hook that relocates a
paired test (round-10 step 6 removed the source kinds' paired-test
relocation): promoting a source draft moves ONLY that draft, and promoting
a test moves only the test. To land a source AND its paired test, promote
each resource yourself (the advisory pairing map above says where the test
belongs); the agent, not the engine, owns that coordination.

The `probe` kind has NO promote: it is a one-root kind (its only location
is `tmp`, root `share/probes/`), there is no project destination, and the
engine accordingly installs no `path_promote` support for it (a promote
request is rejected with "Path kind probe does not support promote").

### Promotion result and reload behavior

After a completed move the promote result always identifies the
destination: `promoted: true` plus `destination`, `promotion_target` and
`promotion_source_target`. It also reports the reload outcome through
`promotion_status` — exactly one of:

- `succeeded` — the default path. The promotion fired the automatic
  workflow reload (`post_move: "workflow_reload"`), and `reload` carries
  the compact report `{ok: true, root, purged, mode}` where `purged` is
  the COUNT of purged feature entries (the full list plus `entrypoint`
  stay in the `reload_workflow` report itself), so the process sees
  current code without any further call.
- `reload_failed` — the move is ALREADY COMPLETE (`promoted: true` and the
  destination keys say so), and only the automatic reload failed:
  `reload: {ok: false, error: <the original diagnostic verbatim>, root}`.
  The same status covers checkout-root discovery failure — a promoted
  target with no `workflow.rb` above it — which reports
  `reload: {ok: false, error: <the climb diagnostic>}` with no `root` key
  (none was derivable). There is no exception envelope for either
  outcome; retrying the promote is pointless (the draft is gone), but
  retrying the reload after fixing the cause is safe.
- `deferred` — you asked for deferral (below); nothing was reloaded yet.

The hook raises only when it cannot construct a report at all (no
`promotion_target` in the promote result).

### Related promotions: defer the reload

Promoting related kinds one at a time fires one reload per promote, and a
mid-sequence reload can evaluate a drafted property against an entity
whose promoted file only lands later — the entity-then-properties case is
the canonical one. Pass the caller argument `defer_reload: true` to each
promote in the sequence instead, and reload once at the end. The
canonical step-by-step sequence (including the wiring order and the
fresh-process verification) lives in the
`scoutcoder-path-kinds-lifecycle` skill; this document deliberately does
not duplicate it.

With no `defer_reload` argument, behavior is unchanged for existing
callers: every promote reloads immediately.


## Wiring after promotion (read this before promoting)

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
  LiveWorkflow loads only `share/` drafts; `workflow.rb` contains no loader
  for `lib/<workflow>/entity/` (that directory does not exist in the
  checkout today).
- A promoted `python_task` file needs no `workflow.rb` line: the workflow's
  OWN `python/tasks` discovery (seeded from `Scout.python.tasks` across the
  path maps) picks it up on the next workflow load in a FRESH process.
  Until that discovery runs — in this process or any other — the promoted
  file is inert. `share/python_tasks` drafts are never auto-loaded either;
  smoke registers them explicitly through `PythonWorkflow.load_directory`.

The wire-up is a deliberate source edit in every case; the path tools never
edit `workflow.rb`. A promoted task also moves its documentation: remove
the `desc` and write the entry in the README's `# Tasks` section with
`document_task` (see [Testing.md](Testing.md) § "Documentation during
promotion").

For lib writes and edits (not promotions), invoke the `reload_workflow`
task explicitly after the edit — nothing runs automatically on write or
edit.

## Trust boundaries

- **`path_run` executes UNSANDBOXED by design.** Path authorization
  authorizes the kind path as a read; the fresh child runs trusted test
  code with the caller's authority. Only expose the `test_file` kind (and
  the `path_run` operation) to agents that may already execute trusted
  Ruby in this checkout.
- **`path_run` with `kind: "probe"` executes UNSANDBOXED by design too**,
  deliberately outside
  the Workspace bwrap mounts so a probe can reach engine checkouts and
  other files no sandboxed exec tool sees. This is the strongest authority
  ScoutCoder hands an agent.
- **No kind relocates files outside its roots**; the agent owns
  cross-resource coordination.
- Entity-before-property ordering is a loader contract: a property file
  whose entity module has not been loaded fails loudly at load time, never
  silently.
- Roots are pinned to absolute paths at registration and every operation is
  authorized against those pinned roots before any callback runs.

Full registration shapes and engine semantics:
[doc/developer/PathKindsInternals.md](../developer/PathKindsInternals.md)
§ "Trust and sandbox registration shapes".

## When to use which

Rule of thumb: the path tools address ONLY the six registered kinds; for
any other file — wiring, docs, data, config — use Workspace.

Create a draft from scratch with `path_write` on the right kind — the kind
root, the validation shape and (for the source kinds) registration on
workflow reload all come with the kind. `path_write` stores whole-file
content you author; the remaining tools read, edit, validate and promote
what is there (plus `path_run` for the two runnable kinds: `kind: "test_file"` runs
tests, `kind: "probe"` runs probes; smoke exists on the source kinds
only). For a probe you specifically want saved-and-run in one call,
`path_run` with `kind: "probe"` and a `source` input does exactly that.

Worked example, one direction each way:

- Authoring a new task draft `greet_user`: `path_write kind=task
  path=greet_user` puts it at the right root (`share/tasks/`), with no
  extension to remember, where `path_validate` checks its shape (`module
  <workflow>` wrapper plus `task` declaration) and a workflow reload
  registers it. The Workspace `write` equivalent (`write
  share/tasks/greet_user.rb`) requires knowing the physical layout,
  validates nothing, and registers nothing by itself.
- Editing `workflow.rb` to wire a promoted task: there is no virtual kind
  for wiring, docs, data or config; use Workspace `read`/`write`/`patch` on
  the real file and retest from a fresh process.

## Lifecycle

The intended loop for one artifact:

1. `path_write` the draft at its `tmp` location.
2. `path_validate` for shape checks.
3. `path_write` the paired test as a `test_file` resource, then run it
   with `path_run` (`kind: "test_file"`, file scope) to see it pass in a
   fresh process.
4. `path_smoke` (SOURCE kinds only) to confirm the draft
   initializes/registers when the real workflow loads; for `test_file`
   resources `path_run` (`kind: "test_file"`) is the executing check —
   there is no smoke.
5. `path_promote` to move the draft to the project side — then promote its
   paired test SEPARATELY through the `test_file` kind (promotion moves one
   resource; nothing auto-relocates the test). A single promote reloads
   immediately; for RELATED promotions (entity then its properties) pass
   `defer_reload: true` to each and reload once after wiring.
6. Wire it into `workflow.rb`; only then is the promoted artifact live.
   After wiring deferred promotions, fire the one explicit `reload_workflow`
   and verify from a fresh process.
