# Path kinds round 10 — test_file kind corrections and `run_test` hardening

Round 10 of the incremental path-kinds implementation (rounds 6–9 built the
kinds; round 9 built `test_file` + `run_test`). A code review approved the
architecture but found defects in the new `test_file` kind; this round
corrected them on the ScoutCoder side and prepared (but could not apply)
the engine-side removal patch. This note is the durable record: what
changed, the evidence for each claim, how to reproduce everything, the
known nuances, and the hand-off state.

**Nothing is committed anywhere.** All ScoutCoder work is uncommitted
working-tree state in `/bulk/mvazque2/git/AgentSuite/ScoutCoder`; the
engine repo `~/git/scout-ai` is untouched by this round (read-only mount).
This is deliberate: the plan's hard constraint was no commits.

## a. Summary — the seven corrections

1. **Smoke removed from `test_file`** (step 2). The `smoke` capability and
   handler are gone from the `test_file` kind; smoke exists only on the
   three SOURCE kinds (`task`, `entity`, `entity_property`) with unchanged
   round-9 semantics. Rationale: `run_test` already executes in a fresh
   process and reports `passed` and exit status separately, so the old "it
   ran" smoke verdict was redundant and masked failing tests. A sweep also
   removed every smoke-on-test_file residue (docs, tasks, tree sweep). Note
   `step2-smoke-removal-sweep.md`.
2. **Canonical virtual-path validation before filesystem inspection +
   kind-root containment** (step 3). A grammar (`path := '' | '.' |
   tier/name+`) is now enforced BEFORE any `File.exist?`/`directory?` call:
   `..`, absolute paths, and extra components are REJECTED
   (`ParameterException`) with zero FS probes recorded; resolved paths are
   contained in the kind root (outside-root symlink rejected, inside-root
   symlink resolved, canary bytes untouched). Probe matrix 5/5 green per
   probe, byte-identical canary. Note `step3-validation-containment.md`.
3. **Single reversible hierarchy-preserving mapping authority** (step 4).
   One module (`PathKindTestFiles`) owns both legs of the virtual↔physical
   mapping; the old duplicate helpers were reduced to synonyms or deleted
   (zero callers in `lib/` before removal). The mapping preserves
   intermediate directories in both directions and is invertible over
   grammar-legal inputs (see the nuance in §d). Note
   `step4-mapping-authority.md`.
4. **Prefix-honoring list** (step 5). `path_kind_list_test_files` now
   filters by the requested prefix instead of globbing the whole root; the
   round-trip suite covers list↔resolve inverse behavior. Note
   `step5-list-prefixes.md`.
5. **Promotion ownership settled** (step 6). No ScoutCoder kind registers a
   `promotion_post_move` hook: `path_promote` moves exactly ONE resource,
   source-kind paired-test relocation is gone, and the agent owns
   cross-resource coordination (promote the test itself through the
   `test_file` kind). Note `step6-promotion-roots-schema.md`.
6. **Registration-time workflow-root resolution** (step 6). The
   `test_file` project root (`Scout.root.test[target_workflow_name]`) is
   resolved when the kind is REGISTERED, not captured at constant-definition
   time, so two differently-named workflows incorporating the kinds in one
   process each get their own project root (two-workflow probe PASS). Note
   `step6-promotion-roots-schema.md`, log `37-step6-two-workflow-probe.log`.
7. **`run_test` schema fixes** (step 6). `scope` is OPTIONAL with a
   documented default (`file`), no longer both required and defaulted;
   timeout bounds documented (per-file integer 1..3600, defaults 120 file/
   directory, 300 suite); `passed` and `ran` are separate booleans and the
   aggregate carries `count/passed/failed/not_run` plus overall `ok`. Note
   `step6-promotion-roots-schema.md`.

## b. Evidence index — every claim → artifact

| # | Claim (criterion) | Evidence artifact |
|---|---|---|
| 1 | Smoke removed from test_file; source-kind smoke intact | `step2-smoke-removal-sweep.md`; capability grep (`test_file.rb` has no `'smoke'` capability/handler); `test_path_kinds.rb:1111,1132,1133` assertions green |
| 2 | Canonical validation before FS inspection; `..`/absolute/extra rejected with 0 FS calls; root containment; canary byte-identical | `step3-validation-containment.md`; probe matrix `26-step3-probes.log` (P-A..P-D stand; **P-E was recorded PRE-step-4** — its first arm (`task/outside_link`) predates the step-4 mapping change, under which that bare spelling is :file-shaped and maps lexically inside the root, so it no longer reproduces; superseded by suite test #17 `test_path_kinds.rb:1002`, which pins BOTH directions: through-symlink traversal (`outside_link/…`) rejected, inside-root symlink allowed, canary untouched); updated probe `probes/step3_pe.rb` + re-run `50-step10b-pe-rerun.out` (5/5, EXIT 0); suite log `27-step3-test-path-kinds.log` |
| 3 | Single reversible mapping authority, hierarchy preserved | `step4-mapping-authority.md`; probe `31-step4-reversibility-probe.log` (`probes/step4_reversibility.rb`); regression `test_path_kinds_roundtrip.rb` (11/18 green) |
| 4 | Prefix-honoring list | `step5-list-prefixes.md`; probe `34-step5-list-probe.log` (`probes/step5_list.rb`); roundtrip suite |
| 5 | Promotion ownership: one resource per call, no post-move hooks | `step6-promotion-roots-schema.md`; `grep -c promotion_post_move` = 0 across kinds; `test_path_kinds.rb` promotion tests |
| 6 | Registration-time workflow-root resolution (two workflows, one process) | `step6-promotion-roots-schema.md` + `37-step6-two-workflow-probe.log` (`probes/step6_two_workflows.rb`) |
| 7 | run_test schema: scope optional/defaulted, timeout bounds, passed/ran split | `step6-promotion-roots-schema.md`; `tasks/test_test_runner_tools.rb` 10/149 green |
| 8 | Engine `test`/`path_test` residue removal **closed via the patch-delivered branch**: patch prepared + dry-run-verified; application PENDING | `step8-engine-patch.md`; dry-run logs `47-step1-patch-dryrun-recheck.txt` (EXIT 0); engine `path.rb` md5 `7ac34d05…` unchanged; residue grep `step8-grep-path_test-engine.txt` + `48-step1-grep-path_test.txt` |
| 9 | Docs state the new truths exactly once; claim-mapped | `step9-docs.md` (18-statement inventory, 12 README edits, 13-row claim map); README.md + guide supersession note (this file's name) |
| 10 | No regression in pre-existing state: 13 pre-existing F/E across 6 areas unchanged through the round | `46-step1-preexisting-identity.txt`; per-file `preexisting-*.out`; final identity in `42-step7-preexisting-failures.txt` |

Fresh-process suite state at round end (all green except the known 13):
`test_path_kinds.rb` 29/496 0F0E · `test_path_kinds_roundtrip.rb` 11/18
0F0E · `tasks/test_test_runner_tools.rb` 10/149 0F0E · engine
`test_path_workflow_integration.rb` 21/68 0F0E · engine `test_sandbox.rb`
16/57 0F0E · engine `test_path.rb` 70/561 with the 13 known env F/E · full
ScoutCoder enumeration **97 tests / 812 assertions** with exactly those 13
(`41-step7-full-suite.txt`; the 57/298 figure quoted in earlier drafts was
the round-START scan in `scoutcoder-full-suite-scan.out`, 9 suites,
predating the roundtrip suite).

## c. Reproduction commands

All ScoutCoder commands run from the checkout root
(`/bulk/mvazque2/git/AgentSuite/ScoutCoder`), each in a fresh Ruby
process. Engine commands run from `~/git/scout-ai`.

```bash
# --- ScoutCoder suites ---
ruby -Itest test/ScoutCoder/test_path_kinds.rb                 # 29 tests / 496 assertions
ruby -Itest test/ScoutCoder/test_path_kinds_roundtrip.rb       # 11 / 18
ruby -Itest test/ScoutCoder/tasks/test_test_runner_tools.rb    # 10 / 149

# Full-suite enumeration (captures the 13 pre-existing F/E):
for f in $(find test -name 'test_*.rb' | sort); do
  echo "=== $f"; ruby -Itest "$f" 2>&1 | grep -E "Failure:|Error:|tests,"
done

# --- Probes (each self-contained, fresh process) ---
ruby tmp/notes/round10/probes/step3_pa.rb     # traversal rejection, 0 FS calls
ruby tmp/notes/round10/probes/step3_pb.rb     # absolute/normalized rejection
ruby tmp/notes/round10/probes/step3_pc.rb     # entity_property arity + prefixes
ruby tmp/notes/round10/probes/step3_pd.rb     # grammar shape table
ruby tmp/notes/round10/probes/step3_pe.rb     # containment + canary
ruby tmp/notes/round10/probes/step4_reversibility.rb   # fwd/back legs inverse
ruby tmp/notes/round10/probes/step5_list.rb            # prefix-honoring list
ruby tmp/notes/round10/probes/step6_two_workflows.rb   # registration-time roots
ruby tmp/notes/round10/probes/round10_step1_recheck_probes.rb  # recheck sweep
ruby tmp/notes/round10/probes/round10_defect_probes.rb         # defect re-anchor

# --- Grep checks ---
# ScoutCoder tree, no path_test residue beyond doc/assertions:
grep -rn "path_test" --include='*.rb' --include='*.md' . \
  | grep -v '^\./tmp/' | grep -v '^\./var/' | grep -v '/\.git/'
# Engine built-in test residue (live until the patch lands):
grep -n '"test" =>' /home/mvazque2/git/scout-ai/lib/scout/llm/agent/path.rb
grep -n 'when "validate", "test"' /home/mvazque2/git/scout-ai/lib/scout/llm/agent/path.rb

# --- Engine patch dry-run (from ~/git/scout-ai; do NOT apply from a ro mount) ---
cd /home/mvazque2/git/scout-ai
patch -p1 --dry-run < \
  /bulk/mvazque2/git/AgentSuite/ScoutCoder/tmp/engine_round9/patches/scout-ai-path-test-removal.patch
git apply --check --verbose \
  /bulk/mvazque2/git/AgentSuite/ScoutCoder/tmp/engine_round9/patches/scout-ai-path-test-removal.patch

# --- Engine suites ---
cd /home/mvazque2/git/scout-ai
ruby -Ilib -Itest test/scout/llm/agent/test_path.rb                     # 70/561, 13 known F/E
ruby -Ilib -Itest test/scout/llm/agent/test_path_workflow_integration.rb # 21/68
ruby -Ilib -Itest test/scout/llm/test_sandbox.rb                        # 16/57
```

## d. Known nuances

- **Inverse-map injectivity holds over grammar-legal inputs only.** The
  project-side inverse leg maps `entity/<a>/test_<b>.rb` back to
  `entity_property/a/b` even for a physical file with no such entity
  property draft (an orphan). Injectivity is NOT violated by this — the
  entity tier's 2-component arity rule (`entity/<name>`) means a real
  `entity` test can never produce `entity/<a>/test_<b>.rb` (that shape is
  grammar-illegal for the entity tier), so the ambiguous preimage exists
  only outside the legal grammar and is REJECTED on validation. Verified by
  the step-4 reversibility probe (`31-step4-reversibility-probe.log`) and
  pinned by the round-trip suite. This is a known, intentional property of
  the mapping, not a defect.
- **"Six pre-existing failures" = six areas, thirteen tests.** The plan's
  phrase refers to six suites/files that contain 13 failing tests total
  (1 failure + 12 errors at round start, unchanged through the round).
  Areas: `test_LiveWorkflow.rb`, `tasks/test_entity_tools.rb`,
  `tasks/test_helper_tools.rb`, `tasks/test_python_task_tools.rb`,
  `tasks/test_task_test_tools.rb`, `tasks/test_workflow_tools.rb`. The
  name-set identity vs the round-start capture is recorded in
  `46-step1-preexisting-identity.txt` (13 names, diff-identical).
- **Engine `test_sandbox.rb` count drift explained.** Round-9 baseline was
  11/34; the current 16/57 is the ENGINE's own five new uncommitted grant
  tests in its working tree (someone else's sandbox-doc work), verified by
  `git diff` on that test file — not a round-10 effect. All 16 pass.
- **Engine `test_path.rb` 13 F/E are environmental** (unchanged name-set
  since round 9; full outputs preserved in `step8-test_path.out` and
  `engine-test_path.out` for byte-level comparison).
- **README pin quirk.** `md5sum README.md` = `ab12682f…` (includes the
  trailing newline); the step-9 note recorded the sha256 digest
  `80acb131…` of the same bytes. Same content, two digest spellings — use
  sha256 (`80acb131…`) when comparing against the step-9 note.

## e. Engine patch — PENDING-APPLY

- **Status: NOT applied.** `path.rb` md5 `7ac34d05ea30c4e86acd081b381fa21d`
  (unchanged); `lib/scout/llm/agent/` byte-identical to engine HEAD
  `4680bd9`; the engine tree still carries its unrelated 12 M + 3 ?? files,
  untouched.
- **Blocker:** the sandbox mounts the engine repo read-only; `git apply`
  failed with `unable to write file 'lib/scout/llm/agent/path.rb' …
  Read-only file system` (EXIT 128, atomic — zero diff in patch scope).
- **Patch:** `tmp/engine_round9/patches/scout-ai-path-test-removal.patch`;
  `patch --dry-run` and `git apply --check` both EXIT 0 against the current
  tree, so no refreshed patch is needed.
- **Recipe (from `step8-engine-patch.md` §7):** from a context where
  `~/git/scout-ai` is writable, run `git apply <patch>`, then verify
  `path.rb` md5 ≠ `7ac34d05…`, then re-run the three engine suites.
- **Expected post-apply deltas:** only built-in-`test`-related tests inside
  `test/scout/llm/agent/test_path.rb` change (the patch rewrites its
  `path_test` assertions); the 13 environmental F/E must remain IDENTICAL;
  `test_path_workflow_integration.rb` 21/68 and `test_sandbox.rb` 16/57
  should stay green. Any other movement is drift, not the patch.

## f. documentation.rb disposition (per Critic precheck)

`lib/ScoutCoder/tasks/documentation.rb`, md5
`13c4e1adb9e7fd2adfee543e97d5a1e1`: **content-inspected clean of round-10
scope** (0 grep matches for test_file / path_test / run_test / path kinds /
smoke / paired test), md5 pinned here, **provenance unattributed** — mtime
2026-10-17 18:11:30, no session-attributable writer (every step-9 edit
targeted README.md or the guide, both ≥18:16), and no git access from this
sandbox to check history. Disposition: **non-material**. It is the
`document_task`/help-docs task file, unrelated to the path kinds; recorded
so the discrepancy is visible rather than hidden.

## g. Out-of-scope follow-ups (unchanged, plus the patch)

- Apply the engine patch (`step8-engine-patch.md` recipe) — the only open
  round-10 deliverable.
- Registration-time validation hardening (grammar is enforced at operation
  time; registration-time self-checks are a possible next hardening).
- Agent-facing wiring (introduce/brief exposure of the kinds).
- Stale Cortex claim flagged in an earlier round (Cortex conversation
  reference to path kinds that predates the round-10 truth).
- Workspace `write` task non-persistence of notes under the checkout
  (path-map default lands them in `~/.scout/tmp/notes/…`; manual copy was
  needed for `round10-baseline-recheck.md` and `step8-engine-patch.md` and
  `step9-docs.md`; in step 10a the `write` task claimed success for this
  very note but the content was NOT found on disk at any candidate location
  and had to be rewritten through bash — logged in
  `tmp/notes/round10/49-step10-repin.md5`).
- scout-gear nil-jobname crash (pre-existing, out of scope).
- The six pre-existing failure areas (13 tests) — still open, still
  identical, still out of scope.

## h. Files changed this round (complete)

**lib/ (ScoutCoder)** — all uncommitted:

| file | purpose |
|---|---|
| `lib/ScoutCoder/path_kinds.rb` | aggregator: kinds registry, shared setup |
| `lib/ScoutCoder/path_kinds/support.rb` | shared helpers incl. kind-root authorization |
| `lib/ScoutCoder/path_kinds/task.rb` | task kind (smoke kept; promote one-resource) |
| `lib/ScoutCoder/path_kinds/entity.rb` | entity kind (2-component arity rule) |
| `lib/ScoutCoder/path_kinds/entity_property.rb` | property kind |
| `lib/ScoutCoder/path_kinds/test_file.rb` | the seven corrections land here (grammar/containment, mapping authority, prefix list, registration-time roots, run_test schema, smoke removal) |
| `lib/ScoutCoder/test_file_support.rb` | runner: timeout bounds, `passed`/`ran` split, aggregates |
| `lib/ScoutCoder/tasks/test_runner_tools.rb` | `run_test` task surface (schema sync) |

**test/ (ScoutCoder)** — all uncommitted:

| file | purpose |
|---|---|
| `test/ScoutCoder/test_path_kinds.rb` | 29 tests / 496 assertions: grammar, containment, arity, promotion, no-smoke-on-test_file assertions (`:1111,1132,1133` left intact) |
| `test/ScoutCoder/test_path_kinds_roundtrip.rb` | NEW this round (step 7): 11/18 mapping round-trip + prefix list |
| `test/ScoutCoder/tasks/test_test_runner_tools.rb` | 10/149 runner behavior (scope defaults, timeout bounds, result shape) |

**Docs:**

| file | purpose |
|---|---|
| `README.md` | 12 edits (step 9): capability asymmetry, trust boundary, doctrine, hierarchical layout, promotion ownership, run_test schema, three engine-claim rewords |
| `research/test-file-path-kind-guide.md` | dated supersession blockquote naming this note |
| `research/path-kinds-round10-test-file-corrections.md` | THIS note (round record) |

**Notes (tmp/notes/, working scratch — not durable):**
`tmp/notes/round10-baseline.md`, `tmp/notes/round10-baseline-recheck.md`,
`tmp/notes/round10/01-…` through `49-step10-repin.md5`, the eight
`step{2..9}-*.md` notes, per-suite `.out`/`.log` captures, and
`tmp/notes/round10/probes/*.rb` (the reproduction scripts in §c).

**Engine (`~/git/scout-ai`): NOTHING changed by round 10.** The prepared
patch sits in the ScoutCoder checkout (`tmp/engine_round9/patches/…`);
the engine's own uncommitted files belong to someone else.

**Committed: nothing, anywhere.**

## Post-write verification

- md5 pins re-taken at step-10a start and stored in
  `tmp/notes/round10/49-step10-repin.md5` (13 files: 5 kind files +
  aggregator, 3 test files, README, guide, documentation.rb, engine
  path.rb).
- The guide's supersession note references this file by its exact path;
  existence verified after writing.
