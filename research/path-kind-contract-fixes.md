# Path-kind contract fixes (round 11)

Date: 2026-10-22. Checkout: ScoutCoder at
`/bulk/mvazque2/git/AgentSuite/ScoutCoder` (HEAD
`bab41ebfd8eeb1d68c538e9569f0f1c01d1e2c77` at round start).
Continuation of the path-kind line: round 8/9
(`research/path-kinds-round8-project-anchored-path-kinds.md`), round 9
(`research/path-kinds-round9-test-file-kind-and-run_test.md`), round 10
(`research/path-kinds-round10-test-file-corrections.md`).

## Motivation

A review of a recorded AGS agent session — Cortex artifact
`reports/ags-path-kind-contract-friction.md`, session evidence at
`main.chat#37-42`, `#44-48`, `#113-117`, `#217/#221` — identified six
tool-contract frictions. Four were fixed in this checkout; two are
engine-side (scout-ai) and are reported out, not patched. This file is
the durable record of the round.

## Fix 1 — run_test child anchor (round-9 deferred item 8, discharged)

**Contract.** A `run_test` child process loads the `workflow.rb` of the
PROJECT CHECKOUT THAT OWNS THE TEST FILE — not blindly the ScoutCoder
checkout. Pre-fix, a test file in a foreign checkout (the AGS regime)
had its child load ScoutCoder's own `workflow.rb`, so foreign
LiveWorkflow drafts and constants were missing in the child.

**Implementation.** `lib/ScoutCoder/path_kinds/test_file.rb:816`
`ScoutCoder.child_checkout(file:, pinned_root:)` chains:

1. `ScoutCoder::PATH_KIND_PROJECT_ROOT` (the regression-suite seam,
   set from `ENV['PATH_KIND_PROJECT_ROOT']` at load time; explicit
   override always wins);
2. `owner_checkout(file)` — `Path.caller_lib_dir(dirname, ['workflow.rb'])`
   marker climb from the test file's directory (the framework's own
   helper, no new marker scheme; see the in-code note about why
   `Workflow.extended`'s default markers climb past a foreign checkout);
3. `pinned_project_root(pinned_root)` — the kind's pinned non-structural
   project root, `<project>/share/test` → project root, accepted only
   when it really is a workflow checkout (`workflow.rb` present) and is
   not this own checkout;
4. `ScoutCoder::PATH_KIND_ROOT` — the structural ScoutCoder checkout
   (final fallback; e.g. a sandbox file under no checkout).

`TestFileSupport.run_child` (`lib/ScoutCoder/test_file_support.rb:214`)
calls exactly this chain. The per-file result hash now carries
`workflow_loaded` (`test_file_support.rb:95`), the absolute path of the
`workflow.rb` the child loaded — visible in both the custom-operation
and the workflow-task result shapes.

**Tests.** `test/ScoutCoder/test_run_test_child_anchor.rb` (new): 4
tests / 9 assertions, clean pass; covers foreign-checkout anchoring,
the ENV override still winning, and the structural fallback for a file
under no checkout. Also `test/ScoutCoder/test_path_kind_contract_fixes.rb`
(new; 10 tests) pins the other fixes' contracts.

**Deliberate deviation, recorded.** The anchor test drives
`TestFileSupport` directly rather than through the `run_test` workflow
task, because the task's job cache key ignores the runtime fixture path
(a `Dir.mktmpdir` fixture would replay a stale job from an earlier
fixture and report a stale `workflow_loaded`). Runner-direct entry gives
a fresh, honest result per fixture.

**Evidence.**
- Harness (foreign checkout `ForeignHarness`, entity `HarnessWidget`):
  `tmp/path-kinds-contract-fixes/harness/`, driver `driver.rb`;
  re-run `ruby driver.rb green` from the harness dir.
  - Red (pre-fix): `tmp/path-kinds-contract-fixes/logs/harness-red.log`
  - Green (post-fix): `tmp/path-kinds-contract-fixes/logs/harness-green.log`
  - Green re-run at final verification:
    `tmp/path-kinds-contract-fixes/logs/verification/harness-rerun.log`
    (`ok=true passed=1 failed=0`, `workflow_loaded=<harness dir>`,
    driver verdict `GREEN confirmed: child loaded the FOREIGN
    workflow.rb (fix works).`)
- Baseline snapshots (pre-round, must not be modified):
  `tmp/path-kinds-contract-fixes/baseline/` (md5-equal copies of the ten
  touched-or-referenced files, plus `git-status.txt`, `anchors.md`,
  `suite.log`).
- Verification log: `tmp/path-kinds-contract-fixes/logs/verification/verification-report.md`.

## Fix 2 — `module ::Gene` accepted by the module-name detector

**What changed.** `lib/ScoutCoder/path_kinds/test_file.rb:96`, shared
helper `path_kind_top_level_modules`:

```ruby
source.scan(/^module\s+(?:::)?([A-Z]\w*)\s*$/).flatten
```

An optional leading `::` is accepted and only the BARE name is captured
(`module ::Gene` is legal Ruby at top level under `Kernel#load` and
still names the bare constant). The shared helper serves both entity
`validate` (module must match the file name) and entity_property
module-match (module must match the entity segment of the path), so one
change fixed both surfaces. Session evidence `main.chat#44-48`.

**Test.** `test_path_kind_contract_fixes.rb` (module-acceptance cases)
— clean pass.

## Fix 3 — engine-side, REPORTED OUT (scout-ai, not patched)

**`path_read kind=task path="."` raises instead of enumerating.**
Fresh-process reproduction (probe script
`tmp/path-kinds-contract-fixes/logs/verification/probe-fix3.rb`, log
`fix3-path-read-root-selector.log`):

```
ParameterException: Path does not exist or is not readable:
/home/mvazque2/git/AgentSuite/ScoutCoder/share/tasks/..rb
  from lib/scout/llm/agent/path.rb:1245 (path_read_text)
```

Root cause chain (engine): `path.rb:1141-1142` `set_extension` applied
to the `.` root selector yields the malformed `..rb` before the read is
attempted. The ScoutCoder kind grammar already forbids dots; the failure
is an engine-side path-resolution edge on the root selector. Reported to
the scout-ai owners with the log as evidence.

## Fix 4 — path-grammar statements in the kind descriptions

**What changed.** All four kind `description` strings now state the
grammar: paths relative to the kind root; no `.rb` suffix; no physical
root prefixes; `entity_property` = `<entity>/<property>`;
`test_file.rb:466-467` additionally: `.` is a root selector only for
enumeration (`path_list`, `run_test` suite scope). The custom op and
task descriptions (`test_file.rb:528`, `tasks/test_runner_tools.rb:5`)
carry the anchor contract sentence. Mirror edits in README
(Agent-path-kinds intro paragraph and the `run_test` task entry).
Session evidence `main.chat#113-117`.

## Fix 5 — engine-side, REPORTED OUT (scout-ai, not patched)

**`path_kinds` ignores its `kind` parameter.** Fresh-process
reproduction (probe `probe-fix5.rb`, log
`fix5-path-kinds-kind-filter.log`): with `kind=entity`,
`kind=entity_property`, `kind=test_file`, and no kind, ALL FOUR calls
return `count: 4` with keys `["task","entity","entity_property","test_file"]`
— the filter is ignored every time.

Engine signature: `lib/scout/llm/agent/path.rb:1285`
`def path_kinds(_args = {})` — the parameter is discarded by the
signature itself. Hook analysis (doc-cited, in the log): scout-ai
`doc/developer/PathEngine.md` §6 declares per-kind `operations` as the
only workflow hook surface, and §7 enumerates `path_kinds` among the ≤12
ENGINE-OWNED tools; no workflow hook exists to filter its output. The
engine fix belongs to the scout-ai owners (either honor the `kind`
argument in the handler or drop the misleading `kind` parameter from the
tool schema).

## README consolidation (this bout)

Five surgical edits, no others (git diff README.md is the authority):

1. `### test_file run_test` — anchor sentence replaced: the child loads
   the `workflow.rb` of the owning project checkout, ENV override noted,
   `workflow_loaded` surfaced, chain detail delegated to this file.
2. Agent-path-kinds intro "project directories" paragraph — tightened
   with the grammar statement (relative to kind root; no physical
   prefixes; no `.rb`; `entity_property` nested; `.` enumeration-only,
   not readable in `path_read`).
3. `validate` / entity bullet — `module ::Gene` (leading `::`) accepted.
4. Spelling rule — half-sentence noting the tmp-side `entity_property`
   spelling `<entity>/<entity>.<property>.rb` differs from the
   source-kind virtual path `<entity>/<property>`.
5. Contradiction sweep — the `## run_test` task entry's "loads the
   checkout's `workflow.rb`" now defers to the anchor contract section.
   Final grep for `loads the checkout's` / `from the checkout root` /
   `loads the checkout`: zero matches.

## Verification summary

- Full suite (recorded, not re-run in the doc bout):
  13 files, 111 tests, 8 failures, 5 errors — all in the
  four known signatures: `path.rb` `outside_grants` drift x4
  (test_path_kinds.rb; engine file drifted past round-9's path.rb:1137
  to :1174/:1387); `TaskNotFound` for define_task/define_helper x6
  (intentionally commented-out requires); define_python_task reload x2;
  test_LiveWorkflow entity-before-property ordering x1. No new signature.
  Assertion total: 805 (12-file reference, suite-after-fix.json) + 37
  (new contract file) = 842; fresh reruns land 842-850 because per-file
  assertion counts drift slightly with environment (seeded fixtures).
  The earlier 802 figure recorded here was a parse of a partial log.
  (test_path_kinds.rb; engine file drifted past round-9's path.rb:1137
  to :1174/:1387); `TaskNotFound` for define_task/define_helper x6
  (intentionally commented-out requires); define_python_task reload x2;
  test_LiveWorkflow entity-before-property ordering x1. No new signature.
- Reconciliation vs the 12-file reference (101/805/8F/5E): exact, once
  the new 10-test contract file is added.
- Seam check: `test_path_kinds.rb` 29 tests / 429 assertions / 3F / 2E
  in the recorded log (verification-report.md; the 433/2F in an earlier
  draft was a different count snapshot); all failures/errors in the
  known drift; seam constants at lines 76-79
  (`remove_const`) and 164 (`const_set`); the override still wins
  post-fix.
- Standing decisions verified: empty `git diff` for `workflow.rb` and
  `lib/ScoutCoder/tasks/workflow_tools.rb`; commented requires at
  workflow.rb:8,9,28,32; commented `#task :define_task` block at
  workflow_tools.rb:250.
- Engine checkout untouched by this round: at verification time
  `git -C /home/mvazque2/git/scout-ai status --porcelain` showed two
  modified files (`agent.rb`, `delegate.rb`) with mtimes 2026-10-21 —
  predating the round — and `path.rb` unmodified since 2026-10-18.
  Note (post-report drift observed by the reviewer): a third local
  modification, `lib/scout/llm/chat/process/tools.rb` (mtime 2026-10-22
  13:52, after the 13:41 verification), appeared after this round's
  changes were complete; its content is unrelated to fixes 3 and 5 and
  it was not produced by this round. The authoritative check for this
  round is `path.rb` (and the whole tree) at verification time.

## Open items

- Fixes 3 and 5 are scout-ai engine-side; the probe scripts and logs
  under `tmp/path-kinds-contract-fixes/logs/verification/` are the
  handoff evidence for the engine owners. Nothing in this checkout can
  fix them.
- **run_test task-surface prefix doubling (recorded, not fixed; out of
  scope).** Invoking `run_test` through the workflow-task surface with a
  project-side directory prefix — e.g. `ScoutCoder.job(:run_test, path:
  "test/ScoutCoder", scope: "directory")` — fails with
  `run_test failed: ...test/test_ScoutCoder.rb is not a directory`: the
  test root appears prepended twice, once by the project-side virtual
  spelling (`test/ScoutCoder` → `test/<workflow>/test_ScoutCoder.rb`)
  and again by the resolution. The tool-level `run_test` surface
  resolves project-side paths correctly (verified: directory scope over
  the project root ran 13 files). A task-surface fix (strip the doubled
  prefix or resolve through the tool spelling) is a candidate for a
  future round.
- Nothing else pending in-checkout: the intended tree delta is exactly
  the six modified lib/task files, two new test files, README.md, and
  this research file.
