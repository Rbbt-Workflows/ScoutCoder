# Path kinds on the Scout Path engine: the `task` kind — round 6 (real-root validation)

Written 2026-10-10, end of round 6. This note consolidates the durable
findings of the round-6 validation of the `task` path kind on the
Scout-AI agent Path engine, executed over the real ScoutCoder roots.
Round 4 established the same kind contract on a scratch root; this note
**cross-references rather than duplicates** it — see
[path-kinds-round4-task-kind-integration.md](path-kinds-round4-task-kind-integration.md)
for the scratch-root design rationale, the hook-arity contract, and the
authoritative list of which engine behaviors were pinned first.

Evidence convention: every claim below cites a recorded probe output under
`tmp/path_kinds/round6/out/` or a step memo under `tmp/notes/`. All probes ran
as fresh Ruby processes through `tmp/path_kinds/round6/record.sh` (command
line, pwd, full stdout/stderr, and exit status captured in each file); every
probe gates on the engine file md5 at start and end.

Engine identity for the whole round: scout-ai HEAD
`3c260f0ddc2d82cb91beb30e4a223e0b90095440` — the author committed
"Refactored path engine and test" at 2026-10-10 12:33, folding in the
mid-round refactor described under *Engine observations* (this note was
finalized two minutes before that commit; a further author commit
`b504275` "Fixed issue with test" landed at 12:55 after this round closed,
leaving the tree clean). Gates pinned to
`lib/scout/llm/agent/path.rb` md5 `e50f4c12faa95d1f142bc81737210c97`,
unchanged across those commits, so every recorded run remains valid.

## Purpose

Introduce and validate a `task` path kind for the Scout Path engine in this
checkout so that agent tooling can manage Scout task files (drafts and
shipped tasks) through one authorized, capability-checked, hook-enriched
surface instead of raw filesystem access. Round 6 proved the kind on the
real roots, with both registration routes, the full operation matrix, the
quality hooks, promotion semantics, and a hostile-input containment matrix —
and closed the residual gaps left by round 4 and the round-5 gap analysis.

## Locations and roots

Declared by `lib/ScoutCoder/path_kinds.rb` (loaded by `workflow.rb`
immediately after the `LiveWorkflow` extension) and registered on the agent
as kind `task`:

| location | root | role |
|---|---|---|
| `tmp` (default) | `share/tasks` | LiveWorkflow drafts — authoring surface |
| `project` | `lib/ScoutCoder/tasks` | shipped tasks loaded by `workflow.rb`'s explicit `require_relative` list |

Paired tests live outside the kind roots by convention (see *Test hook
conventions*). The roots are absolute and resolve inside the checkout
(`tmp/path_kinds/round6/out/register_smoke.txt` rows 1c-1d).

## Kind definition summary

`lib/ScoutCoder/path_kinds.rb` declares the single kind `task` via the
`ScoutCoder::PATH_KINDS` constant:

- locations `tmp`+`project`, default `tmp`; roots as above; `sandbox: true`;
- capabilities on: read/write/edit/list/move/rename/delete/validate/test/
  promote/smoke; `patch` off (task files are whole-file authored, and the
  engine's patch op stays reserved);
- hooks: `validate` (4-arg static checks), `test` (writes + runs the paired
  test fresh-process), `smoke` (fresh-process workflow load + registration
  assert), `promotion_destination => 'project'` (declarative) plus
  `promotion_post_move` (relocates the paired test).

The file is the definition of record; this note does not duplicate its
source. Round 4 fixed the hook-arity and Hash-form contract the engine
expects; the current engine (`path.rb` + `path/workflow_kinds.rb`) still
matches it — every hook call in the recorded probes succeeded with the
round-4 arity.

## Registration routes

Two routes, both proven against the current engine
(`tmp/path_kinds/round6/out/register_smoke.txt`, REGISTER_SMOKE 17/17,
exit 0):

1. **Instance route** — `agent.register_path_kind('task', ScoutCoder::PATH_KINDS['task'])`
   on a fresh `LLM::Agent`: kind registered with the declared
   locations/roots/capabilities; the 12 path tools installed
   (`path_kinds, path_read, path_write, path_edit, path_list, path_move,
   path_rename, path_delete, path_validate, path_test, path_promote,
   path_smoke`); `path_patch` correctly absent.
2. **Whole-workflow incorporation** — `tool: ScoutCoder` (whole workflow, no
   task token) through the real `Agent#ask` (mock backend): the kind is
   incorporated from the workflow constant, deep-duplicated (the shared
   constant is never mutated), same 12 tools. **Task-level incorporation
   (`tool: ScoutCoder <task>`) does NOT incorporate the kinds** — the
   registry stays empty, matching the round-4 finding on the current engine.

Re-registration idempotence: two consecutive whole-workflow incorporations
leave a single kind and no duplicated tools; a direct in-process
`integrate_workflow_path_kinds(ScoutCoder)` after an ask-driven one is a
no-op.

## Lifecycle & capabilities

Real-root CRUD through the engine tools only
(`tmp/path_kinds/round6/out/lifecycle2.txt`, LIFECYCLE 15/15, exit 0):
write → read byte-identical → edit (line selector, line count preserved) →
edit-restore to canonical bytes → list both locations → rename → read →
rename back → move within tmp → read at new path → move back → delete →
absent → re-write. The generic operations behave as an exact filesystem view
over the roots; every intermediate state matched expectation.

## Test hook conventions

The `test` hook (evidence: `tmp/path_kinds/round6/out/test2.txt`,
TEST_PROBE_OK; `tmp/path_kinds/round6/out/project_fail.txt`, PROJECT_FAIL
7/7):

- **tmp side** — paired test at `share/test/task/<name>.rb`;
- **project side** — paired test at `test/ScoutCoder/tasks/test_<name>.rb`;
- the hook writes the paired test when none exists (generated harness
  asserting registration, and the `desc` convention for tmp drafts), records
  its path and content hash, then executes it in a **fresh process**;
- verdicts are distinguishable: a passing body yields `ok=true`, exit 0,
  with the test-unit output captured; a failing body yields `ok=false` with
  the failure visible in the recorded stdout
  (`tmp/path_kinds/round6/out/test2.txt` shows both; the green run of
  `hello_r5` and a deliberately failing sibling);
- the hooks are **location-symmetric**: an invalid project-side task is
  caught exactly like a tmp-side one
  (`tmp/path_kinds/round6/out/project_fail.txt` rows
  `validate-fails-project-side` and `paired-test-fails-fresh-process`).

The paired-test directories are outside the kind roots by design: the hook
is trusted plugin code and writes there deliberately; this is a documented
round-4 trust boundary (round-4 note, *Containment residuals*), not an
authorization defect.

## Promote semantics

Evidence: `tmp/path_kinds/round6/out/promote.txt` (PROMOTE_PROBE_OK, 8/8,
exit 0) and `tmp/path_kinds/round6/out/malicious.txt` (MALICIOUS 6/6, exit 0).

- **Success** — declarative `promotion_destination => 'project'`: the engine
  resolves and authorizes the destination itself, performs the move
  (`promoted=true`), and the destination content is byte-correct.
- **No-clobber** — an existing destination is refused with
  `Promotion destination already exists: ... (pass overwrite ...)`;
  destination bytes untouched, source intact.
- **Overwrite** — with `overwrite: true` the destination is replaced
  byte-correctly and the source is removed.
- **Failure leaves source intact** — bad location
  (`Location "elsewhere" is not supported`), absent/traversal source
  (`Path access denied by sandbox (outside_grants)`), and hostile
  destinations all deny before any mutation; after all denials the tmp
  draft, tmp test and project placeholder were byte-identical to before.
- **Paired-test relocation** — `promotion_post_move` moves the tmp-side
  paired test to the project-side location (content SHA preserved).
- **Malicious-definition negative** — a hostile kind (absolute `/tmp`
  destination, `../` destination, or a relative root) cannot make promote
  write outside its own grants: `Location "/tmp" is not supported by path
  kind evil` / `outside_grants` / `Path sandbox requires absolute
  filesystem paths`; no partial writes at any watched escape target; the
  real kind still registers cleanly afterwards.
- **Nuance (round-6 finding)** — promotion moves the *file*; it does not
  auto-register the task in the running workflow. `workflow.rb` loads
  `lib/ScoutCoder/tasks/*.rb` through an explicit `require_relative` list,
  so a promoted task needs one wiring line (applied for `hello_r5` in step
  4, `tmp/notes/round6-matrix.md` § hello_r5 disposition). The promoted
  file itself loads and registers when required.

## Authorization matrix

Evidence: `tmp/path_kinds/round6/out/containment.txt` (CONTAINMENT 24/24)
plus `containment-evidence.txt`; edit-side additions in
`tmp/path_kinds/round6/out/edit_symlink.txt` (EDIT_SYMLINK 4/4).

All denials are semantic `ParameterException` envelopes
(`Path access denied by sandbox (outside_grants)` and friends) returned by
the installed tool — never raw exceptions — and every denial is issued
**before any mutation** (authorization precedes plugin callbacks):

| attack | ops probed | verdict |
|---|---|---|
| `../` traversal write (both locations) | write | denied; outside targets absent |
| absolute path outside grants and `/tmp` (both locations) | write | denied; targets absent |
| traversal cross-location (tmp↔project) | write | denied (only the requested location's root is authorized) |
| symlink escaping the root | read, write | denied; sentinel byte+mtime unchanged |
| deeper-inside symlink (parent inside root, target in another tree) | read, write, **edit**, **move** | denied; outside target byte-identical (`edit_symlink.txt`) |
| move with traversal destination | move | denied; **source intact** |
| promote with traversal/absent source | promote | denied; seeds intact |
| hostile kind definitions | promote | denied at operation time (see *Engine observations*) |

Tree-integrity snapshots before/after the whole containment run are
identical; the sentinel and 18 watched outside target paths stayed clean
throughout.

## Engine observations

- **Mid-round refactor (engine evolution, not regression).** Between steps 3
  and 4 the author's working tree moved the whole-workflow
  PATH_KINDS machinery out of `path.rb` into the new
  `lib/scout/llm/agent/path/workflow_kinds.rb` (module
  `AgentPathWorkflowKinds`, included from `path.rb`); `path.rb` shrank by
  117 lines. Gates moved `b79295c2…` → `e50f4c12…`; all round-6 probes were
  re-pinned and re-run green, and the author's own new split test files
  (`test_path_edit/errors/filesystem/patch/promotion/workflow_integration.rb`)
  plus `test_path.rb` were green on the new layout
  (`tmp/notes/round6-baseline.md`, `tmp/notes/round6-matrix.md` § engine
  drift). No probe assertion depended on the removed code.
- **Hostile kinds register (by design).** `register_path_kind` validates
  only name, sandbox boolean, and default-location membership; it accepts
  relative roots and out-of-grant `promotion_destination` values. Containment
  is enforced at operation time against the declared roots, and the engine's
  own tests pin exactly those call-time denials
  (`test_path_promotion.rb`: `test_promotion_denies_destination_location_without_configured_root`,
  `test_promotion_denies_destination_traversal`). No engine test pins
  registration-time laxity, so it is design (registration is a
  trusted-author action), not a defended accident.
- **Hardening recommendation (report-only; no engine patch made).** Extend
  the existing registration-time validations (pattern:
  `test_path.rb` `test_register_path_kind_rejects_*`) to also reject
  non-absolute `roots` entries and require a declared `promotion_destination`
  to be a Hash whose `location` names a declared, rooted location — turning
  the already-pinned call-time denials into immediate `ParameterException`s
  at the author's feet, with the operation-time checks unchanged as the real
  security boundary. Full text: `tmp/notes/round6-gaps-closed.md` § 4.
- **Known unrelated failure no longer reproduces.** The pre-existing
  `test/scout/llm/agent/test_attach.rb` failure (annotation.rb-rooted,
  flagged in round 4/5) now passes 8/8 in both the mirror and the live tree;
  the annotation test file is gone from the tree
  (`tmp/notes/round6-baseline.md` § surprises).

## Conventions & recipe — adding another path kind in this checkout

1. Extend `ScoutCoder::PATH_KINDS` in `lib/ScoutCoder/path_kinds.rb` with a
   new kind entry: `locations` + `roots` (absolute paths inside the
   checkout), `capabilities`, and the optional 4-arg hooks (`validate`,
   `test`, `smoke`) and declarative `promotion_destination` +
   `promotion_post_move`. Hook arity and the Hash form follow the round-4
   contract (round-4 note, *Hook contract*).
2. Roots must be absolute (relative roots fail closed at operation time
   with `Path sandbox requires absolute filesystem paths` — recorded in
   `malicious.txt`); `default_location` must be a declared location
   (engine-enforced).
3. Reload the workflow (`require './workflow'`): the constant is consumed by
   `integrate_workflow_path_kinds(ScoutCoder)` on whole-workflow
   incorporation; nothing registers kinds from task-level `tool:` lines.
4. Probe it fresh-process with an md5 gate on `path.rb` (the round-6
   `record.sh` convention) — the engine is under active development and the
   gate is what caught the mid-round refactor.
5. Keep paired-test/auxiliary hook writes inside the checkout and outside
   the kind roots deliberate and documented (trusted-plugin trust boundary).

## Open items & next steps

- **hello_r5 draft disposition** — the tmp draft `share/tasks/hello_r5.rb`
  is currently the probe seed (rewritten by every lifecycle run); the
  promoted copy `lib/ScoutCoder/tasks/hello_r5.rb` is wired in `workflow.rb`
  — at line 31, applied in step 7b after the step-4 wiring edit was lost to
  the write-tool sandbox mapping; evidence
  `tmp/path_kinds/round6/out/hello_r5_wired.critic-fix.txt` (exit 0) —
  and its relocated paired test is green (2 tests, 0 failures, run via the
  convention loader: require `./workflow`, then load the test file). Decide
  whether to keep the draft as a standing probe fixture or remove it once
  the round is closed (its promoted copy would then also be a candidate for
  removal unless the demo task is wanted).
- **Uncommitted state / commit decision (user decision).**
  `lib/ScoutCoder/path_kinds.rb`, the `workflow.rb` wiring (path-kinds load
  + `hello_r5`), the promoted `hello_r5` task and its paired test are all
  uncommitted. Recommendation: **keep the kind in `lib/` and commit it** —
  it is validated, self-contained, documents its own contract, and is the
  working API for any further kind; the `hello_r5` demo pair is small and
  doubles as a shipped example of the promote round trip. `share/` drafts
  stay tmp-only by convention (LiveWorkflow reload surface).
- **Engine hardening** — the registration-time validation recommendation
  above is reported for the engine author; nothing patched here.
- **Advisories carried forward** — TOCTOU between authorization and
  filesystem mutation remains an accepted advisory (round-4 note), and
  `path_dispatch`/custom-resolver kinds inherit the trusted-plugin model:
  a `resolve` hook can bypass `roots`-based sandboxing unless the kind
  declares a root grant (engine `path_authorize!` comment; round-4 note).

## Evidence index

| claim | evidence |
|---|---|
| registration, both routes + tools + idempotence | `tmp/path_kinds/round6/out/register_smoke.txt` (17/17); memo `tmp/notes/round6-step3.md` |
| lifecycle CRUD round trip | `tmp/path_kinds/round6/out/lifecycle2.txt` (15/15); first run `lifecycle.txt` shows the probe repairs |
| validate pass/reject matrix | `tmp/path_kinds/round6/out/validate2.txt` |
| test hook write + fresh-process PASS/FAIL | `tmp/path_kinds/round6/out/test2.txt` |
| smoke hook | `tmp/path_kinds/round6/out/smoke2.txt` |
| promote semantics (success/no-clobber/overwrite/failure-intact/relocation) | `tmp/path_kinds/round6/out/promote.txt` (8/8) |
| malicious-definition containment | `tmp/path_kinds/round6/out/malicious.txt` (6/6) |
| containment matrix + deeper-inside symlink (read/write) | `tmp/path_kinds/round6/out/containment.txt` (24/24) + `containment-evidence.txt` |
| edit/move through deeper-inside symlink | `tmp/path_kinds/round6/out/edit_symlink.txt` (4/4) |
| project-side failing draft (location symmetry) | `tmp/path_kinds/round6/out/project_fail.txt` (7/7) |
| engine identity, suites, drift attribution | `tmp/notes/round6-baseline.md`, `tmp/notes/round6-matrix.md` § engine drift |
| scope, gap inventory, round numbering | `tmp/notes/round6-scope.md` |
| residual-gap closure + `]` removal + hardening text | `tmp/notes/round6-gaps-closed.md` |
| scratch-root contract, hook arity, advisories | [path-kinds-round4-task-kind-integration.md](path-kinds-round4-task-kind-integration.md) |
