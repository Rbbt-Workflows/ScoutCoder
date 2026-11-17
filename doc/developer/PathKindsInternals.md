# Path kinds internals

Engine-level registration facts, capability matrix, ratification status and
registration shapes for the six ScoutCoder agent path kinds. The
operational how-to (authoring, validating, testing, promoting with the
`path_*` tools) lives in
[doc/user/PathKinds.md](../user/PathKinds.md); engine semantics themselves
are documented in scout-ai `doc/developer/PathEngine.md` § "3. Registering
a kind" and "8. Callback contract and trust boundary".

## Registration

ScoutCoder registers six path kinds on the scout-ai agent path engine:
`task` (Scout workflow task files), `entity` (Scout entity module files,
one file per entity), `entity_property` (entity property files, addressed
through nested `<entity>/<property>` virtual paths), `python_task` (Scout
Python task source files, one `.py` per task), `test_file` (unit and
integration test files, addressed through tier paths such as
`task/greet_user`, `integration/round_trip` or `python_task/my_task`) and
`probe` (unsandboxed ScoutCoder-only Ruby snippets for investigating the
Scout framework itself, addressed as a bare name under `share/probes/`).
They expose the authoring surfaces of the current project's own workflow
(ScoutCoder's own definitions live in `lib/ScoutCoder/path_kinds.rb`; the
kinds are defined by the workflow of the current directory) as virtual
filesystems an agent operates with the generic `path_*` tools: the
`path_kinds` listing tool plus one tool per operation — `path_read`,
`path_write`, `path_edit`, `path_list`, `path_move`, `path_rename`,
`path_delete`, `path_validate`, `path_smoke` and `path_promote` — with no
per-kind tool fan-out, plus the two custom operations installed as their
own tools: the `test_file`-kind `run_test` and the `probe`-kind
`run_probe`. ScoutCoder does not register a `test` capability or handler;
explicit test execution is provided by `run_test`. `path_patch` is not
offered for any kind.

Which kinds an agent receives is decided by the `path_kind:` chat role, not
by tool lines: an explicit `path_kind: ScoutCoder` line loads all six kinds,
`path_kind: ScoutCoder probe` loads only `probe` (names accumulate across
lines and within a line), and a task-level tool line registers no kinds.
Agents without a start_chat file default to loading every kind of their own
workflow.

**Canonical note on the removed legacy `path_test`.** The Scout-AI engine's
older built-in `test` operation conflated test creation and execution with
source-kind operations and obscured the execution-versus-authorization
distinction. It is slated for removal, but its removal patch may still be
unapplied in the engine checkout: if a legacy `path_test` tool remains
visible, do not use or depend on it, and do not register a kind-level `test`
handler. ScoutCoder's supported design manages test files as `test_file`
resources and executes them explicitly through `run_test`.

## Capability matrix

Capabilities are NOT identical across the six kinds: the four SOURCE kinds
(`task`, `entity`, `entity_property`, `python_task`) offer validate + smoke
+ promote; `test_file` offers validate + promote and **no smoke** (round-10
decision); `probe` offers validate (syntax only) and a single custom
operation, `run` — no smoke, no promote, no second location. For
`test_file`, `validate` is the static check and `run_test` is the executing
check — `run_test` reports `passed` and the exit status separately, so the
old "ran OK even if the tests failed" smoke verdict was redundant and was
removed. For `probe`, `validate` is a pure AST parse that never executes the
file; `run_probe` is the only executing surface.

`path_read`, `path_write`, `path_edit`, `path_list`, `path_move`,
`path_rename` and `path_delete` behave as an exact filesystem view over the
kind's roots. `patch` is off for all six kinds (whole-file authored
sources), and no kind registers a `test` capability.

## Kind roots (two locations, one-root kinds)

Each of the five Ruby-file kinds except `probe` has two locations: `tmp`
(default) and `project`. For the four source kinds (`task`, `entity`,
`entity_property`, `python_task`), `tmp` holds source drafts; only the Ruby
ones among them are loaded by LiveWorkflow (Python drafts are never
auto-loaded — registration is the workflow's own `python/tasks` discovery,
see [Testing.md](Testing.md) and the user wiring guide). For `test_file`,
the locations carry test resources that are never loaded automatically; it
has THREE locations (`tmp`, `project`, `python`). `path_promote` MOVES one
resource from `tmp` to `project`, where promoted source files are not
loaded automatically. `probe` has ONE location only (`tmp`, the default)
and no promote: a probe is never promoted, only run. Roots follow the
current project — relative Scout-path declarations are pinned to it once at
registration, and every operation authorizes against the pinned roots —
and are declared per kind:

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
draft at `share/entity_properties/DemoWidget/tag_palette.rb` and, after
promotion, at `lib/<workflow>/entity/DemoWidget/tag_palette.rb`; a Python
task draft at `share/python_tasks/my_task.py` and, after promotion, at
`python/tasks/my_task.py`. Path Engine virtual paths omit the physical root
and the file suffix (`.rb` for the Ruby kinds, `.py` for `python_task`).

`entity` and `entity_property` deliberately share the project root: promoted
entity files are flat `<entity>.rb` and promoted property files are nested
`<entity>/<property>.rb` below it. The `entity_property` virtual path is
nested for the same reason — one declarative promotion destination covers
the whole kind. A flat property path (`tag_palette.rb`) is a validate
error, not a second supported shape.

`test_file` is the odd one out: it manages TEST files, not source drafts,
and its roots cover unit and integration tests on both sides. The virtual
path's FIRST segment is the tier — `task`, `entity`, `entity_property`,
`python_task`, `helper`, or the marker `integration` — and unit vs
integration is decided purely by that first segment (`integration/...` is
an integration test; everything else is a unit test).

The `python_task` tier is exceptional: it lives ONLY at the `python`
location (`python/test`, `Scout.python.test`) and maps DIRECTLY under that
root as `test_<name>.py` — the legacy scout-rig convention. The tier
directory is virtual-only there (no physical `python_task/` subdirectory),
and a FILE-shaped request for any OTHER tier at the `python` location is
rejected (`... hosts only the python_task tier`). At the Ruby locations
`python_task` is an ordinary open tier with the generic `.rb` rules; the
`python` location is that tier's home.

## Tier-mapping convention status

The project-side task/entity/entity_property spellings are implemented and
pinned by the regression suite (`test/<workflow>/test_path_kinds.rb` and
`test/<workflow>/test_path_kinds_roundtrip.rb`). The entity-tier `<Type>`
spellings (CamelCase canonical, legacy snake own-spelling) and the
parsing-free map (D2) are RATIFIED by the decision artifact
`var/cortex/artifacts/reports/entity-case-convention-decision.md`
(corrected path; formerly cited as bare `reports/…`). The `helper`
project-side spelling `test/<workflow>/helpers/test_<name>.rb` remains
unratified: it was derived by symmetry with the `share/test/helper/` draft
side and has no precedent in the checkout. `integration` is round 9's own
convention on both sides, with the same uniform `test_` prefix as every
other tier.

## No-autorun contract (settled, round 13)

The original round-12 ask was auto-run: writing or editing a probe through
the GENERIC path tools would execute it. The engine contract (outcome C;
DC-1/DC-2, `tmp/notes/round12-engine-contract.md`) makes that impossible
without fighting the engine: generic `path_write` never consults a kind's
operation table, and a `path_edit` override is treated as a content
transform only, whose fixed result shape cannot carry an execution report.
So the design deliberately does NOT try — ratified in round 13 with a
behavioral canary (`tmp/path_kinds/round13/no-autorun-evidence.md`) and the
two pin tests: the generic operations `path_write`, `path_edit`,
`path_read`, `path_list`, `path_move`, `path_rename` and `path_delete`
NEVER execute a probe — they are pure file operations over the kind root —
and create-and-run lives in the `run` custom operation's `source` input,
which is the channel custom operations provide (payload returned verbatim,
exactly like `run_test`).

The same no-autorun principle covers lib edits: nothing runs automatically
on `path_write`/`path_edit` or Workspace writes under `lib/`; the explicit
`reload_workflow` task is the reload surface (mirroring how `run_test` is
invoked after writing a test).

## Promotion reload hook

The five promoting kinds (`task`, `entity`, `entity_property`,
`python_task`, `test_file`) register the engine's `promotion_post_move`
hook with one shared lambda
(`ScoutCoder::WorkflowReload::PROMOTION_POST_MOVE`): after the engine has
performed the move — the hook is never the writer — it derives the owning
checkout root from the promote args (climbing to the first directory
containing `workflow.rb`; a foreign root fails loudly, which the engine
surfaces with the completed move intact) and runs the full workflow reload
(see [LiveWorkflow.md](LiveWorkflow.md) § workflow-level reload). The
wiring line in `workflow.rb` is still the agent's explicit edit (the hook
reloads the checkout; it does not wire anything), but once wired-or-not,
the process sees current code. Known behavior, not a defect: the
`path_promote` TOOL result does not surface the hook's `post_move` report —
the reload's effect is evidenced by outcome (the promoted code registered
and runnable), not by a visible field.

## Trust and sandbox registration shapes

- **`run_test` executes UNSANDBOXED by design** (round-10 step 6). The
  `test_file` kind declares `sandbox: true` like the source kinds, but that
  flag governs which operations the agent may call, NOT how the custom
  operation executes: `run_test` is registered as a `:full` handler with
  `authorization: :read`, so the kind path is authorized as a read while
  the fresh child process runs test code with the authority of the caller —
  path authorization is not a process sandbox. Test source is trusted code;
  expose the `test_file` kind (and the `run_test` task) only to agents that
  may already execute trusted Ruby in this checkout.
- **`run_probe` executes UNSANDBOXED by design too** (round 12), with the
  same registration shape (`:full`, `authorization: :read`) and the same
  consequence: the kind declares `sandbox: true`, the probe path is
  authorized as a read, and the fresh child runs the probe with the
  caller's authority — deliberately outside the Workspace bwrap mounts, so
  a probe can reach engine checkouts and other files no sandboxed exec tool
  sees. This is the strongest authority ScoutCoder hands an agent: reserve
  the `probe` kind for agents already trusted to run arbitrary Ruby in this
  checkout.
- **No kind relocates files outside its roots.** The round-9 paired-test
  relocation hooks were removed in round-10 step 6; nothing writes outside
  the kind roots on promotion anymore, and the agent owns cross-resource
  coordination.
- Entity-before-property ordering is a loader contract. A property file
  whose entity module has not been loaded fails loudly at load time — the
  underlying error surfaces; it is never a silent no-op — so property files
  always load after their entity files (see
  [LiveWorkflow.md](LiveWorkflow.md) for the combined lib/share load
  order). The smoke hook catches a wrong-order draft because it runs in a
  fresh process.
- Sandboxing is on for all six kinds: `entity`, `entity_property`,
  `test_file` and `probe` declare `sandbox: true` explicitly, `python_task`
  and the `task` kind rely on the engine default, which is `true`. Roots
  are pinned to absolute paths at registration — the recommended spelling
  is a relative Scout path such as `Scout.share.tasks` or
  `Scout.lib['<workflow>'].tasks`, pinned against the current project — and
  every operation is authorized against those pinned roots before any
  callback runs.
