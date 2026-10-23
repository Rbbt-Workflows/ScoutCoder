# Path kinds round 13 — legacy tool retirement, directive-1 ratification, root-spelling verification

Round 13 of the incremental path-kinds implementation (rounds 6-12 built
the six kinds, the `probe` kind, and the README baseline). This round
executed three user directives: (1) ratify the no-autorun channel on
write/edit for probes — already the shipped behavior, so this round was
verification plus record-keeping; (2) retire ten legacy tools from code
entirely; (3) verify the probe root spelling is `share/probes`. The round
ran as five bouts: a read-only investigation (fresh baseline +
deletion-scope ledger), the sweep + verification, the independent
root-spelling diagnostic, the start_chat workflow-guidance rewrite, and
the consolidation bout that wrote §m and closed the record. This
note is the durable record for the independent Critic gate (which
passed; see `tmp/path_kinds/round13/critic/verdict.md`).

**Nothing is committed anywhere.** All work is uncommitted working-tree
state in `/bulk/mvazque2/git/AgentSuite/ScoutCoder` (rounds 6-13
accumulate). The engine checkout `/bulk/mvazque2/git/scout-ai` was read
only (fingerprints, source frames); its defect candidates DC-1/DC-2/DC-3
remain recorded, never patched.

## a. Summary

1. **Directive 2 — ten legacy tools retired from code entirely.** Ten
   files deleted (five task/support files, five test files), four files
   trimmed (workflow_tools.rb, entity_tools.rb, test_entity_tools.rb,
   workflow.rb), README swept (two `##` entries, one see-also bullet, one
   supports sentence), two prose name-drops reworded. Final exported exec
   surface in a fresh process: exactly `[job_info, job_status,
   list_entities, run_probe, run_task, run_test]`
   (`retirement-sweep.md` §2b).
2. **Directive 1 — no-autorun ratified on fresh behavioral evidence.**
   The production-kind canary (write → no marker, edit → no marker,
   validate → no marker, run_probe → marker with content `edited`)
   passed end-to-end, and both pin tests are green in the post-sweep
   tree (`no-autorun-evidence.md`). README now states the contract as
   settled (`## Probe run_probe` §"No-autorun contract (settled, round
   13)").
3. **Directive 3 — `share/probes` confirmed sole spelling.** Zero `shre`
   hits on the live surfaces, no misspelled or singular directory on
   disk, registration root `Scout.share.probes` resolves to the checkout
   `share/probes` (`root-spelling-check.md`).
4. **Suite posture.** Baseline (fresh, pre-change): 136 tests / 6 F /
   3 E, an exact name-by-name match to the expected 9-item set
   (`baseline-summary.md` §3-4). Post-sweep: **110 tests / 2 F / 0 E**,
   exactly the two expected non-tool residue items; all 7 tool-linked
   F/E gone with their carrier files (`post-sweep-suite.out`).
5. **Manager decisions 1-4 executed as binding** (§e) and recorded as
   follow-ups in the Cortex artifact `round13/retirement-followups.md`
   (written at consolidation, §m.5).
6. **Deviations recorded** (§f: four deliberate a-d, plus (e), an
   evidence-handling slip found and corrected while writing this note),
   including the engine-pin observability caveat and the deliberate
   retention of the round-13 fingerprint integration file.
7. **Directive 3 independently reproduced** by a separate bout (§m.1,
   `root-spelling-report.md` + `probe-corpus/`): `Scout.share.probes`
   resolves via `Path#method_missing` join (no pathmap key — uniform with
   every sibling kind), engine pinning lands it in the checkout, every
   surface spells `share/probes` identically; plural ratified. The same
   bout surfaced the probe write-placement quirk (§i).
8. **start_chat workflow-guidance rewritten** by a fourth bout (§m.2):
   the four-phase numbered procedure now in "Development doctrine";
   config block byte-identical, Chat.parse verdict CLEAN
   (`../new_doctrine/work/chat-parse-scoutcoder-startchat-workflow-receipt.txt`).

## b. The retirement inventory (directive 2)

Authoritative sweep instruction: `tmp/path_kinds/round13/deletion-ledger.md`
(built from fresh greps in the investigation bout, adopted by the
Manager). Execution record: `tmp/path_kinds/round13/retirement-sweep.md`.

### Deleted whole (10 paths)

```
lib/ScoutCoder/tasks/task_test_tools.rb      lib/ScoutCoder/task_test_support.rb
lib/ScoutCoder/tasks/helper_tools.rb         lib/ScoutCoder/helper_test_support.rb
lib/ScoutCoder/tasks/python_task_tools.rb
test/ScoutCoder/tasks/test_task_test_tools.rb
test/ScoutCoder/tasks/test_helper_tools.rb
test/ScoutCoder/tasks/test_python_task_tools.rb
test/ScoutCoder/tasks/test_workflow_tools.rb
test/ScoutCoder/test_task_test_support.rb
```

### Trimmed (4)

- `workflow.rb` — live `require_relative … python_task_tools` removed;
  the three commented requires (task_test_tools / helper_tools /
  helper_test_support) removed. 1272 → 1048 bytes.
- `lib/ScoutCoder/tasks/workflow_tools.rb` — `module TaskDefinition`
  (L6-40) and the commented `define_task` block (L242-342) removed; dead
  `ripper`/`fileutils` requires dropped. 346 → 209 lines. The live
  list_tasks / task_inputs / task_code / task_dependencies / run_task /
  job_info / job_status tasks are untouched.
- `lib/ScoutCoder/tasks/entity_tools.rb` — the `define_entity` and
  `define_entity_property` task bodies (L317-424) removed; dead
  `stringio` require dropped. 425 → 316 lines. `list_entities`,
  `EntityDefinitionSupport` and the loader order kept (both still green
  in the post-sweep suite).
- `test/ScoutCoder/tasks/test_entity_tools.rb` — only the
  `EntityToolsTest` class (L9-296) removed; `ListEntitiesTest` and
  `EntityLoaderOrderTest` kept intact. 448 → 159 lines.

### README (1) + prose (3)

- `README.md`: see-also bullet for
  `scout-rig doc/user/DefiningPythonTasks.md` removed (named
  `define_python_task`); `## define_python_task` and `##
  author_python_task_test` sections removed; the legacy-supports
  sentence reworded to "retired in round 13"; the probe no-autorun
  paragraph reworded from "Outcome-C deviation" to "No-autorun contract
  (settled, round 13)".
- `lib/ScoutCoder/test_file_support.rb` L19/L397: two `TaskTestSupport`
  prose name-drops reworded.
- `lib/ScoutCoder/path_kinds/test_file.rb` L166/L536: two
  `author_python_task_test` comment name-drops reworded to "the retired
  legacy authoring tool" (this is the extra edit outside the ledger
  list — deviation c, §f).

### Final surface and kind set

Fresh process (`retirement-sweep.md` §2b):

```
exec: [:job_info, :job_status, :list_entities, :run_probe, :run_task, :run_test]
kinds: entity entity_property probe python_task task test_file
```

The six kinds are unchanged; `run_test` and `run_probe` remain the two
custom executing operations; the async inspection surface
(list_tasks/task_inputs/task_code/task_dependencies, documentation
helpers, document_task) is unchanged.

### The `define_task` interpretation (must be read with the sweep)

The acceptance criterion "zero hits in lib/" is met under this
documented interpretation: a `grep -rn -w define_task lib/ test/
workflow.rb README.md` returns exactly ONE live hit —
`lib/ScoutCoder/python_task_support.rb:125`, a Ruby **method** named
`define_task` inside the support module kept whole by Manager decision 4.
It is not a tool: there is no `task :define_task` declaration, no
`export_exec`, and no agent-visible registration anywhere. Excluding
that kept module, the live-surface count is **0/10** for all ten retired
names (`retirement-sweep.md` §2a, and the final sweep verified at
claim-map row 3.3). If the module is trimmed in a later round (optional
follow-up), the literal zero follows.

## c. Directive 1: no-autorun ratified (verification, not new work)

No code changed for directive 1 — the round's contribution is fresh
behavioral evidence plus record-keeping:

- **Canary (production kind, no sandbox copy).** A probe whose body
  writes a marker file is exercised through the real agent wiring
  (`LLM::Agent.new` + `integrate_workflow_path_kinds(ScoutCoder)`):
  `path_write` → marker absent; `path_edit` (selector
  `{type: lines, start: 0, end: 2}`) → marker absent, on-disk body
  byte-identical to the replacement; `path_validate` (ok: true) →
  marker absent; then `run_probe` executes job
  `ScoutCoder/run_probe/Default_15c6307c724f724adc6ac4ee6ef58d7c.json`
  and the marker appears with content `edited` — the POST-EDIT body
  ran, closing the loop (the edit wrote text and never executed it).
  Raw transcript `tmp/path_kinds/round13/no-autorun-evidence.raw`;
  marker kept as evidence `tmp/path_kinds/round13/canary-marker.txt`
  (regenerated by the consolidation bout's canary re-run 2026-10-23;
  the round-13 sweep copy had been cleaned during canary cleanup — the
  raw transcript `.raw` carries the same marker check on every run).
- **Pin tests green post-sweep** (2 tests, 8 assertions, 0 F/E):
  `test_probe_generic_write_never_auto_runs`
  (test_path_kinds.rb:1801) and
  `test_probe_validate_never_executes_valid_or_invalid` (:1727);
  raw `tmp/path_kinds/round13/pin-tests.out`.
- **Engine side reading (light, grep-level).** On the observable engine
  copy, `def path_write` (path.rb L1314-1341) parses args, checks
  capability, resolves, authorizes, writes text — it never reads
  `operation_table`; `path/edit.rb` greps clean for override
  consultation. Recorded in `baseline-summary.md` §1 with the
  fingerprint caveat below.

Ratification ledger effect: item 1 of the round-12 ledger (§l) is
RESOLVED as ratified; README states it as the settled contract.

## d. Directive 3: root spelling already correct

`share/probes` (plural) is the sole spelling, verified on three axes
(`tmp/path_kinds/round13/root-spelling-check.md`, raw
`tmp/path_kinds/round13/shre-sweep.out`):

1. `grep -rn "shre" README.md workflow.rb lib/ test/` → zero hits
   (exit 1, no lines selected).
2. On-disk tree: `share/probes` exists; `shre` and `share/probe` do not
   (`ls -d` both fail); `share/probes/` holds only
   `motivating_outside_grant.rb` after canary cleanup.
3. Registration: `lib/ScoutCoder/path_kinds/probe.rb:61` pins
   `'tmp' => Scout.share.probes`; live resolution in a fresh process
   yields the checkout `share/probes` directory (recorded in
   `root-spelling-check.md` §4).

Ratification ledger effect: item 2 RESOLVED (confirmed, not changed).

## e. Manager decisions (executed this round, binding)

Relayed from the deletion ledger by the Worker, decided by the Manager
before the sweep:

1. **with_scout_import coverage: ACCEPT THE LOSS.**
   `test_python_task_tools.rb` deleted whole, including
   `test_define_python_task_preserves_future_import_and_existing_scout_import`.
   Rationale: `PythonTaskSupport.with_scout_import` becomes dead code
   once `define_python_task` is gone; testing dead code has no value.
   Follow-up: a later trim of python_task_support.rb deletes the method.
2. **test_second_workflow_augments_top_level_entity_with_property:
   ACCEPT THE DELETION.** The behavior stays covered by
   `test/ScoutCoder/test_LiveWorkflow.rb` and `EntityLoaderOrderTest`
   (baseline evidence; both green post-sweep).
3. **list_tasks/run_task/job_info/job_status unit-test gap: ACCEPT,
   pre-existing.** The deleted `test_workflow_tools.rb` covered only the
   retired TaskDefinition/define_task surface; no direct unit tests for
   those live tasks exist today. Open item, not a blocker.
4. **python_task_support.rb: KEEP WHOLE, untouched.** The dead methods
   stay this round (see §b's define_task interpretation); optional
   follow-up trim. The `python_task` kind consumes only `validate_name`
   and `validate_python_source` (path_kinds/python_task.rb L80/97/165/172).

Worker findings (not decisions): the deletion ledger's four open
questions (TaskDefinition consumers, support-module consumers, entity
test mix, python_task_support consumers) were all answered with grep/read
citations before the sweep and adopted by the Manager unchanged.

## f. Deviations (a-d deliberate and resolved; (e) an evidence-handling slip found and corrected in this bout)

- **(a) Engine pin not directly re-hashable this round.** The round-12
  pin `c1d9e3516c79174eb7a590f8408ee4ef` (md5 of the Scout::Path
  implementation `path.rb` under `/bulk/mvazque2/git/scout-ai`) could
  not be re-verified by direct hashing: the engine lib tree is not
  mounted into this session (only `/bulk/mvazque2/git/scout-ai/tmp` is;
  verified in both sandbox layers and from the unsandboxed `run_test`
  child, where `File.file?` returns false — raw
  `tmp/path_kinds/round13/engine_fingerprint_unsandboxed.out`). Verdict
  recorded as **"no drift observed; pin unverifiable this round, reason
  recorded"** via the byte-identical observable gem copy
  (`scout-ai-2.1.0`, md5 `0d55806e…`, 66 069 bytes, `path_write` at
  L1314), which is itself identical to round 12's recorded bwrap view.
  The light no-autorun reading (§c) was performed against that copy.
- **(b) `share/test/integration/round13_engine_fingerprint.rb` created
  and RETAINED** (Manager decision): mirrors the round-12 persisted
  equivalent, preserves fingerprint reproducibility, never enters the
  suite (`find test -name 'test_*.rb'` walks only `test/`), reachable
  only via explicit `run_test --path integration/…`.
- **(c) One edit outside the ledger list.** `lib/ScoutCoder/path_kinds/
  test_file.rb` L166/L536 comment reword (naming "the retired legacy
  authoring tool" instead of `author_python_task_test`). The zero-hit
  acceptance criterion forced it; two comment lines, no behavior.
- **(d) Canary script ROOT bug.** Three early script revisions resolved
  `ROOT` one level too high, so `path_write` reported success against a
  path outside the checkout; three `r13_canary_*` probe drafts were left
  behind and later deleted (`ls share/probes/` shows only
  `motivating_outside_grant.rb`, raw in `shre-sweep.out`). No marker was
  ever created by those runs — no-autorun held even in the misdirected
  writes. The final runner (`tmp/path_kinds/round13/run-canary.rb`) is
  correct and is the one whose transcript is cited.

- **(e) Pre-change raw suite output overwritten** (discovered while
  writing this note; not deliberate). The sweep bout launched the
  post-sweep suite through this round's own
  `run-baseline.sh`, whose hardcoded `OUT=tmp/path_kinds/round13/
  baseline-suite.out` clobbered the pre-change raw (the file now holds
  the post-sweep run; md5-identical to `post-sweep-suite.out`). The
  pre-change evidence survives as (1) the totals + 9-item F/E table
  transcribed into `baseline-summary.md` §3 while the raw was intact
  (with a correction note added at the top of that file), and (2) the
  independent round-12 raw `tmp/path_kinds/round12/after-full-suite.out`
  (identical 9-name F/E set, 136/6F/3E, names verified 9/9 by sorted
  diff). Root cause: the runner script was written for the baseline bout
  and reused verbatim for the post run instead of parameterizing OUT.
  Lesson recorded: a reusable suite runner must take its output path as
  an argument.

## g. Suite posture (baseline → post-sweep)

| | tests | assertions | F | E |
|---|---|---|---|---|
| Pre-change baseline (fresh, investigation bout) | 136 | 1162 | 6 | 3 |
| Post-sweep (same command, fresh) | 110 | 1011 | **2** | **0** |
| Post-consolidation (root-spelling bout, fresh; §n) | 110 | 1015 | **1** | **0** |
| Critic independent (critic/full-suite.out) | 110 | 1011 | **2** | **0** |

- Pre-change evidence: the totals and the 9-item F/E table in
  `tmp/path_kinds/round13/baseline-summary.md` (§3: exact name-by-name
  match to the expected set — HelperTools×2, PythonTaskTools×2,
  TaskTestTools×1, WorkflowTools×2, LiveWorkflow×1, path_kinds×1).
  **Deviation (e) applies to the raw file:** `baseline-suite.out` was
  overwritten during the sweep bout (see §f-e); the on-disk file of that
  name now holds the post-sweep run. The independent round-12 raw
  `tmp/path_kinds/round12/after-full-suite.out` confirms the identical
  9-name F/E set at 136 tests / 6 F / 3 E (assertions 1152 vs 1162,
  run-to-run variance; names 9/9 identical — verified by sorted diff).
- Post-sweep raw: `tmp/path_kinds/round13/post-sweep-suite.out` (totals
  re-verified by awk sum of its per-file summary lines: 110 / 1011 /
  2 / 0). Residue exactly:
  `test/ScoutCoder/test_LiveWorkflow.rb ::
  test_entities_load_before_entity_properties` (F) and
  `test/ScoutCoder/test_path_kinds.rb ::
  test_task_smoke_constructs_job_without_executing` (F). All seven
  tool-linked F/E disappeared with their carrier files (deleted);
  expected under the round-13 after-suite criterion. **7 of the 9 walked
  files rc=0** (6 suite files + `test/test_helper.rb`, which runs 0
  tests); the two residue carriers rc=1. *(Corrected 2026-10-23 after
  the Critic gate: the earlier text said "Eight suite files rc=0",
  overcounting by one; verdict
  `tmp/path_kinds/round13/critic/verdict.md` D1.)*
- The kind-set pin assertion
  (`test_source_kinds_drop_test_operation_but_keep_relocation`, which
  walks `ScoutCoder::PATH_KINDS`) is inside `test_path_kinds.rb` and
  green (54 tests / 1 F in that file = the single known residue).
- README internal links: 44/44 resolve against 49 headings
  (`tmp/path_kinds/round13/check-readme-links.rb`, GitHub slugger rules).- README internal links: 44/44 resolve against 49 headings
  (`tmp/path_kinds/round13/check-readme-links.rb`, GitHub slugger rules).
- Post-consolidation rows explained in §n: the 1-F run is the same tree
  with item 9 flaking out in its favor (it passes isolated); the two
  2-F runs are the same tree in full-suite context. All within the
  post-sweep prediction; no new failure names anywhere.

## h. Ratification ledger update (round-12 §l → round-13 state)

| # | item | state after round 13 |
|---|---|---|
| 1 | Outcome-C no-autorun channel (`run_probe source` create-and-run; generic ops never execute) | **RESOLVED — ratified** (user directive 1; evidence §c; README settled) |
| 2 | Root spelling `share/probes/` (plural) | **RESOLVED — confirmed** (directive 3; §d) |
| 3 | Single-probe scope for `run_probe` (no directory/suite scope) | **STANDING** default, unchanged this round |
| 4 | Timeout envelope (default 120 s, 1..3600) | **STANDING** default, unchanged this round |
| 5 | Entity third-state tools (`define_entity`/`define_entity_property` exported or retired) | **RESOLVED — retired**, executed this round (§b) |

## i. Open items and follow-ups

Follow-up ledger (Manager decisions 1-4 + retained deviation file):
Cortex artifact `round13/retirement-followups.md`.

Standing from earlier rounds (unchanged by round 13):

- **DC-1 / DC-2 / DC-3 engine defect candidates** (round-12 note §c/§k):
  `overrides['write']` silently dead; `path_edit` override-type ignored
  (arity crash; non-String return escapes the wrapper raw); PathEngine.md
  gap. Recorded candidates only — the engine checkout was never patched.
- **Handler normalization burden / `kind` stripped from custom-op args /
  path_promote failure-shape inconsistency / AST message quirk**
  (round-12 §k): all standing, none addressed this round.
- **`test_task_smoke_constructs_job_without_executing`** — item-9 flake
  status update *(consolidation bout)*: in the consolidation-time fresh
  suite run (`tmp/path_kinds/round13/root-spelling-suite.out`, 110
  tests / 1015 assertions / **1 F** = item 8 only) the test was ABSENT
  from the failure list, and every isolated fresh-process invocation
  this round passed (`1 tests, 6 assertions, 0 failures`). The
  round-12 hypothesis "environment drift in the smoke child" stands;
  the test remains recorded-F in `post-sweep-suite.out` and both
  baselines, i.e. flaky in the recorded direction (fails in full-suite
  context, passes isolated). Still out of round scope; owner should
  decide whether to stabilize or accept the flake.
- **Round-11 open items** (`research/path-kinds-round11-python-task-kind.md` §i):
  the draft-root ratification (`share/python_tasks/`) and the
  legacy-task removal question are both now MOOT for the removal half —
  this round removed the legacy python tools; the engine's
  list/resolve extension asymmetry and the `python` location naming
  note remain recorded.
- **Unit-test gap** (Manager decision 3): no direct unit tests for
  list_tasks / run_task / job_info / job_status. Open item.
- **Probe write placement** *(consolidation addendum; detail §m.1)*:
  `run_probe --source` from a chat whose CWD is the AgentSuite ROOT
  saves probes into the parent repo's `AgentSuite/share/probes/`
  (relative root resolved against the invoking process's map), while
  the custom-operation surface, the suite and the canary write into
  `ScoutCoder/share/probes`. Discovered when seven `round13_*` probe
  files accumulated in the parent repo; preserved at
  `tmp/path_kinds/round13/probe-corpus/`, scratch tree deleted. Fix
  candidates NOT applied: a one-line pin in
  `ProbeSupport.agent_standin.resolve_path` (`probe_support.rb`), or
  engine-side anchoring of `:current` to the owning checkout (Scout-ai
  work). Also recorded in Cortex `round13/retirement-followups.md` and,
  as a standalone durable finding with both receipts and both fix
  candidates, in Cortex `round13/probe-write-placement.md` (written at
  consolidation).
- **Pre-change baseline snapshot unrecoverable** (deviation (e), §f): a
  true pre/post pair must be taken at the NEXT change, not reconstructed.
- **Uncommitted state**: rounds 6-13 accumulate as working-tree state in
  this checkout; nothing committed anywhere, by standing instruction.

## m. Consolidation addendum (final bout, 2026-10-23)

*(Section lettering: the consolidation sections were inserted before the
sweep bout's existing §j/§k/§l rather than renumbering them — append-only
discipline; §n sits with §m because it is the consolidation's own suite
confirmation.)*

This section is the consolidation bout's record. It does not rewrite any
earlier bout's sections; it adds what was missing so the note covers all
of round 13, with end-state evidence produced against the tree as it
stands now.

### m.1 Directive 3 — independent reproduction of the root-spelling result

A second bout (the root-spelling diagnostic) re-ran the diagnostic from
scratch rather than citing §d; full report
`tmp/path_kinds/round13/root-spelling-report.md`, probe sources preserved
at `tmp/path_kinds/round13/probe-corpus/` (7 files). Findings, all from
`run_probe` receipts (fresh unsandboxed children preloading
`ScoutCoder/workflow.rb`):

- **Resolution mechanism.** `Scout.share` is the relative Scout path
  `"share"` (a String extended with `Path`); `Scout.share.probes` is
  answered by `Path#method_missing` (`scout-essentials/lib/scout/
  path.rb:45`) — an implicit directory join, NOT a pathmap key.
  `Scout.share.probes == Scout.share.join('probes')` → true.
  `Scout.path_maps` contains no `probes` — nor `tasks`, `entities`,
  `entity_properties` or `python_tasks`: **no share subdir segment is a
  pathmap-registered name, for any of the six kinds.** The mechanism is
  uniform, so `probes` is exactly as registered as every sibling.
- **Engine pinning.** At kind registration the engine resolves the
  relative root against the effective map and pins it absolute
  (`path_pin_roots!`, gem scout-ai-2.1.0 `path.rb:305`, called at :144).
  Live receipt (`round13_root_pinning_resolved`): all six kinds pin
  into the ScoutCoder checkout; `probe` pins `tmp =
  /bulk/…/AgentSuite/ScoutCoder/share/probes` and is the only one-root
  kind.
- **Spelling comparison — every surface identical** (table in
  `root-spelling-report.md` §2): kind registration
  `lib/ScoutCoder/path_kinds/probe.rb:61` (`Scout.share.probes`),
  runner fallback `lib/ScoutCoder/probe_support.rb:57` (same), task
  desc `lib/ScoutCoder/tasks/probe_tools.rb:6` (`share/probes/`),
  physical dir `ScoutCoder/share/probes/` (plural), README kinds-table
  probe row (`share/probes`, one-root, promote-less), tests
  (`KIND_TMP_SUBDIR['probe'] => 'probes'` and pin paths), `workflow.rb`
  (no probe-root mention — roots come from the kind definition).
- **Negative-evidence greps.** `shre` and singular sweep across
  `lib/ test/ workflow.rb README.md research/ start_chat share/`:
  rc=1 everywhere (the single `research/…round13….md` hit is the sweep
  bout's own negative-evidence sentence, i.e. documentation of the
  check).
- **Verdict (matches §d, independently reached): no misspelling or
  inconsistency exists.** Plural `share/probes` is the deliberate
  spelling, consistent with every sibling convention; §h item 2 stands
  as RESOLVED. No ScoutCoder source change was invented (stop rule).
- **Best reading of the user's intent:** round-12 §l item 2 had flagged
  the plural spelling as unratified; directive 3 settles that
  ratification.

**Probe write placement (observation → open item).** During the same
bout, seven `round13_*` probes were found in the PARENT repo's
`AgentSuite/share/probes/` — all created by that bout's own
`run_probe --source` calls from this chat, which runs at the AgentSuite
root. Relative kind roots are pinned by the incorporating PROCESS, so
task-surface saves landed one level up; the custom-operation surface,
the suite and the canary all write into `ScoutCoder/share/probes`
(`no-autorun-evidence.raw` shows the canary probe written inside the
checkout). Not a spelling defect — a where-you-run artifact. Cleanup:
corpus preserved, scratch `share/` deleted from the parent repo;
recorded as an open item in §i and in Cortex
`round13/retirement-followups.md`.

### m.2 start_chat workflow-guidance rewrite (fourth bout)

A separate bout rewrote the workflow-guidance portion of
`ScoutCoder/start_chat`: the single recall paragraph under "Development
doctrine" was replaced by a numbered four-phase working procedure —
(1) check Cortex, (2) read documentation when required only, (3) probe
documentation gaps and write to Cortex using the `probe` path kind, and
(4) loop until done on the Path engine (write → test → verify →
document). Working-tree diff: `start_chat` +34/−10 lines (34
insertions, 10 deletions) against HEAD; the trailing config block
(from `tool: Cortex cortex_write` to the end) untouched.

Validation receipt (parent repo — the file is in the submodule, the
receipt lives outside it):
`new_doctrine/work/chat-parse-scoutcoder-startchat-workflow-receipt.txt`:

- Parse profile before (HEAD) vs after (worktree): 11 messages each;
  role multiset identical (`exec_task, import(2), introduce(2),
  system(2), tool(4)`); 10 directive lines byte-identical; stray-role
  scan clean.
- Trailing config block sha256 `b6607abf…393acd83` on BOTH sides —
  byte-identical, 183 bytes, and the file tail.
- Post-processing survival: whole-workflow tool lines expand to the
  full sets (ScoutCoder includes `run_probe`, `run_test`, `run_task`,
  `job_info`, `job_status`, docs and list tasks; no retired names).
- Verdict: **CLEAN**. Method documented in
  `new_doctrine/work/startchat-validation.md`; executed as a probe
  through the `probe` path kind.

### m.3 Fresh-process exported surface (re-run at consolidation time)

```
$ ruby -Ilib -e 'require "./workflow"; puts ScoutCoder.exec_exports.sort.inspect;
                 puts ScoutCoder::PATH_KINDS.keys.sort.inspect'
exec: [:job_info, :job_status, :list_entities, :run_probe, :run_task, :run_test]
kinds: ["entity", "entity_property", "probe", "python_task", "task", "test_file"]
```

Raw: `tmp/path_kinds/round13/consolidation-surface-listing.txt`.
`run_probe` exported; `retirement-sweep.md` §2b's surface re-confirmed.
Retired-name grep re-run at consolidation time
(`tmp/path_kinds/round13/consolidation-grep.txt`): across
`lib/ test/ workflow.rb start_chat share/`, nine of the ten names
rc=1 (zero hits); `define_task` rc=0 with the ONE known tolerated hit
`lib/ScoutCoder/python_task_support.rb:125: def define_task(workflow,
name, source)` — the kept support-module METHOD, not a tool (§b
interpretation; Manager decision 4).

### m.4 README dead-name grep (re-run at consolidation time)

```
$ grep -n -w "define_task\|define_helper\|define_python_task\|author_task_test\
  \|run_task_test\|author_helper_test\|run_helper_test\|author_python_task_test\
  \|define_entity\|define_entity_property" README.md
(no output; rc=1)
```

README (1235 lines) contains NONE of the ten retired names. Clean.

### m.5 Provenance of this note's sections

- **Retirement sweep (§b-§g of this note; deletion-ledger.md,
  retirement-sweep.md, baseline-summary.md, the deleted/trimmed files
  themselves):** attributed to the round-13 sweep bout ONLY as
  "an earlier bout in this round" — no job id, no Scout job path, no
  author name is recorded anywhere in the note or the tmp evidence.
  The one concrete job reference inside the round's evidence is the
  canary's `ScoutCoder/run_probe/Default_15c6307c724f724adc6ac4ee6ef58d7c.json`
  (§c), and that job file is NOT on disk now — a fresh probe
  (`round13_consolidation_job_pin`, corpus-preserved) searched all four
  plausible job roots (`ScoutCoder/var/jobs`,
  `AgentSuite/var/jobs/ScoutCoder`, `~/.scout/var/jobs`) and found
  neither the id nor any `ScoutCoder/run_probe` job directory: the
  canary's job artifacts were cleaned (the round-12 note records this
  cleanup discipline; the canary marker and raw transcript remain).
  Verdict: **the sweep bout's work is verifiable only through its
  on-disk artifacts and this note; its producing job/agent identity is
  UNATTRIBUTED.** Nothing further is claimed. (Correction,
  consolidation: the probe listed THREE roots in its output but FOUR in
  its candidate list — the fourth, `SCOUT_JOB_DIR`, was nil in that
  environment, which is why only three appear; the search itself covered
  every root the environment actually had.)
- **Root-spelling diagnostic (§m.1):** this session's ScoutCoder bouts;
  receipts are the tool outputs preserved in
  `root-spelling-report.md` + `probe-corpus/`; no Scout job ids.
- **start_chat rewrite (§m.2):** attributed to its own bout via the
  receipt it left; the receipt cites its method document and was
  produced through `run_probe`.
- **Consolidation (this section, §i/§f extensions, the reconstructed
  Cortex follow-up ledger):** this bout. The Cortex artifact
  `round13/retirement-followups.md` cited by §a5/§i was MISSING until
  now (`cortex_list type=artifacts` showed no round13 artifacts;
  `cortex_search "round13"` → no matches); this bout reconstructed it
  verbatim from §e/§f with an explicit provenance note inside the
  artifact, so the note's citations resolve. This bout also wrote the
  standalone Cortex finding `round13/probe-write-placement.md` (§i
  probe-placement item, with receipts and both fix candidates).

## n. Post-consolidation suite (no source change; confirmation)

No ScoutCoder source file changed during consolidation (the only
touches were this note, tmp evidence, the parent-repo receipt already
on disk, and the Cortex artifact). The current-tree suite evidence
standing at round-13 close is `tmp/path_kinds/round13/
root-spelling-suite.out` (110 / 1015 / 1 F / 0 E — item 8 present,
item 9 absent-and-isolated-passing) plus the critic's independent run
(`critic/full-suite.out`, 110 / 1011 / 2 F / 0 E — both residues,
item 9 failing in its full-suite context). Both are within the recorded
post-sweep prediction; the item-9 difference between them is the flake
itself, characterized in §i.

## j. Evidence index

All under `tmp/path_kinds/round13/` unless prefixed:

| file | what it holds |
|---|---|
| `baseline-summary.md` | engine fingerprint + caveat, suite command, pre-change F/E table (9 items), expected-set comparison; correction note (deviation e) at top |
| `baseline-suite.out` | ⚠ deviation (e): now holds the POST-sweep run (identical to post-sweep-suite.out); the pre-change raw was overwritten by the reused runner. Pre-change evidence: baseline-summary.md §3 + round-12 `after-full-suite.out` (names 9/9) |
| `deletion-ledger.md` | authoritative sweep instruction: hit inventory, four questions answered, per-file dispositions, pre-edit md5s |
| `cross-check-greps.txt` | per-name grep dump backing the ledger |
| `engine_fingerprint_unsandboxed.out` | unsandboxed fingerprint transcript (gem copy identity, /bulk observability) |
| `run-baseline.sh` | the suite command used both rounds (fresh process per file) |
| `retirement-sweep.md` | execution record: edits file-by-file, grep proofs, fresh-process load dump, kind-set verification |
| `post-sweep-suite.out` | raw post-sweep suite output (110/2F/0E) |
| `no-autorun-evidence.md` (+ `.raw`, `pin-tests.out`, `canary-marker.txt`, `run-canary.rb`) | directive-1 canary sequence + both pin tests |
| `root-spelling-check.md` (+ `shre-sweep.out`) | directive-3 sweep, share/ tree, registration citation |
| `root-spelling-report.md` (+ `root-spelling-suite.out`, `probe-corpus/`) | the independent root-spelling diagnostic bout (§m.1): resolution mechanism, spelling table, negative-evidence greps, the probe-placement observation, its own suite run (110/1015/1F) |
| `consolidation-surface-listing.txt` | fresh-process exec/kind listing at consolidation time (§m.3) |
| `consolidation-grep.txt` | ten retired names re-grepped at consolidation time (§m.3) |
| `check-readme-links.rb` | README internal-link checker (44/44 resolve) |
| `critic/` (+ `verdict.md`) | the independent Critic gate's own commands and outputs (PASS; D1 correction applied to §g) |
| Cortex `round13/probe-write-placement.md` | durable standalone record of the probe write-placement quirk, receipts + both fix candidates (§i) |
| `final-existence-sweep.sh` (+ `.out`) | existence sweep: all cited paths resolve, deleted paths absent, suite totals spot-checked |
| `research/path-kinds-round12-probe-kind.md` | round-12 note (structural template; §l ledger) |
| `tmp/notes/round13-claim-map.md` | this round's claim map (every claim → evidence path) |
| Cortex `round13/retirement-followups.md` | follow-up ledger (decisions 1-4, retained file; reconstructed at consolidation with an internal provenance note — §m.5) |
| `../new_doctrine/work/chat-parse-scoutcoder-startchat-workflow-receipt.txt` (PARENT repo) | the start_chat rewrite validation receipt (§m.2); outside the submodule by that bout's choice |

## k. Reproduction

```bash
cd /bulk/mvazque2/git/AgentSuite/ScoutCoder
bash tmp/path_kinds/round13/run-baseline.sh        # suite, fresh process per file
ruby tmp/path_kinds/round13/run-canary.rb          # directive-1 canary (production kind)
ruby -Itest test/ScoutCoder/test_path_kinds.rb -n "/test_probe_generic_write_never_auto_runs|test_probe_validate_never_executes_valid_or_invalid/"
ruby tmp/path_kinds/round13/check-readme-links.rb  # README links
ruby -Ilib -e 'require "./workflow"; p ScoutCoder.exec_exports.sort; p ScoutCoder::PATH_KINDS.keys'
scout workflow task ScoutCoder run_test --path integration/round13_engine_fingerprint

# consolidation-time verifications (§m.3, §m.4)
ruby -Ilib -e 'require "./workflow"; puts ScoutCoder.exec_exports.sort.inspect; puts ScoutCoder::PATH_KINDS.keys.sort.inspect'
for n in define_task define_helper define_python_task author_task_test run_task_test \
         author_helper_test run_helper_test author_python_task_test define_entity define_entity_property; do
  grep -rn -w "$n" lib/ test/ workflow.rb start_chat share/; done   # only the python_task_support.rb:125 method
grep -n -w "define_task\|define_helper\|define_python_task\|author_task_test\|run_task_test\|author_helper_test\|run_helper_test\|author_python_task_test\|define_entity\|define_entity_property" README.md   # rc=1

# root-spelling probes (probe-corpus/ holds the sources; re-run by name from the checkout root)
scout workflow task ScoutCoder run_probe --path round13_root_pinning_resolved
```

## l. Commit status

Nothing committed anywhere, by standing instruction. All work is
uncommitted working-tree state in
`/bulk/mvazque2/git/AgentSuite/ScoutCoder`: the deletions, the trims, the
README refresh, this research note, the round-13 claim map, and the
evidence under `tmp/path_kinds/round13/` (plus the retained
`share/test/integration/round13_engine_fingerprint.rb`). The engine
checkout `/bulk/mvazque2/git/scout-ai` was only read.

**Consolidation bout's commit status (unchanged):** no commits made by
any round-13 bout. The consolidation touches were this note (§a, §g,
§i, §m, §n, §j, §k extensions), the two new tmp evidence files
(`consolidation-surface-listing.txt`, `consolidation-grep.txt`), one
probe added to `probe-corpus/`, the reconstructed Cortex artifact
`round13/retirement-followups.md`, and the deletion of the scratch
parent-repo `share/probes/` tree (untracked, never part of the
submodule). The start_chat rewrite and its parent-repo receipt belong to
the fourth bout; the submodule `start_chat` change is likewise
uncommitted.
