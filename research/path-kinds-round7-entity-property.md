# Path kinds on the Scout Path engine: `entity` + `entity_property` — round 7

Written 2026-10-11, end of round 7 (plan step 8 of 10: consolidation). This
note is the durable record of adding two path kinds to the Scout-AI agent
Path engine surface from the ScoutCoder checkout: `entity` and
`entity_property`, extending the round-6 validated `task` kind
([path-kinds-round6-task-kind.md](path-kinds-round6-task-kind.md), which
cross-references the round-4 scratch-root contract in
[path-kinds-round4-task-kind-integration.md](path-kinds-round4-task-kind-integration.md)).

Evidence convention: every claim below cites a recorded probe output under
`tmp/path_kinds/round7/*/out/` or a step memo under `tmp/notes/round7-*.md`.
All probes ran as fresh Ruby processes recorded by the round-6 `record.sh`
convention (command line, pwd, engine path.rb md5 gate, full stdout/stderr,
exit status in each `.txt/.err/.exit` triplet). Superseded intermediate
recordings (nonzero exits from mid-run debugging) are indexed explicitly in
the evidence index and are NOT counted as failures. Where evidence is partial
or a limit applies, the text says so instead of overclaiming.

## Purpose and scope

Round 7 added and validated `entity` and `entity_property` path kinds so an
agent can draft, validate, test, smoke and promote Scout entity modules and
their properties through the generic path-tool surface, exactly as round 6
did for workflow tasks. The work was programmatic probing only: the engine
trees (`~/git/scout-ai`, `~/git/scout-gear`) were read-only and pinned by md5
gates, all changes landed in the ScoutCoder checkout
(`lib/ScoutCoder/path_kinds.rb`, probe trees under `tmp/`, one permanent test
file), and no engine file was modified at any point.

## Environment and drift control

| pin | value | evidence |
|---|---|---|
| scout-ai HEAD | `b504275d471a150c6c080df08a6815dce22b797c` ("Fixed issue with test"), porcelain CLEAN before and after every suite | `tmp/path_kinds/round7/baseline/pins.txt`; re-verified end-of-round `containment/out/post_cleanup_listing.txt` |
| scout-gear HEAD | `23c5b1f3f1071fa6b3938396d83b621fd03bb48d`, porcelain CLEAN | same |
| engine gate | `lib/scout/llm/agent/path.rb` md5 `e50f4c12faa95d1f142bc81737210c97` — **unchanged start-to-end**; asserted by every `record.sh` header and re-verified in the end-state listings | header of every `tmp/path_kinds/round7/*/out/*.txt` |
> **Round-9 supersession note (2026-10-14):** the engine pin in this row is
> historical. The live checkout at the time of round 9 has
> `lib/scout/llm/agent/path.rb` md5 `2a6a0c9b3e79d37d91e30754b1dc8511` at
> scout-ai HEAD `e9663f930d401bbba2c752c82cb1a55eb3a827c9` ("Pin agent path
> roots to configurable Scout maps"), with a dirty tree (`M agent.rb`,
> `M path.rb`, `M sandbox.rb`). Under that engine, `Agent#resolve_path`
> raises `NoMethodError: undefined method 'find' for an instance of String`
> at `path.rb:1137` for the path kinds' `write` operations — the round-7
> green baseline is not reproducible against it (pre-attributed as engine
> drift in `tmp/path_kinds/round9_worklist.md` §B.5 and the round-9 test
> logs). Do not re-pin; treat this row as the round-7 record only.
| sibling engine files | `path/edit.rb` `20299fc7…`, `path/patch.rb` `310e2f4e…`, `sandbox.rb` `1682020c…` | `tmp/path_kinds/round7/baseline/pins.txt`; `tmp/notes/round7-baseline.files/md5_path_files.out` |
| ruby | 3.3.1 (2024-04-23 c56cd86388) | `tmp/path_kinds/round7/baseline/pins.txt`; `tmp/notes/round7-baseline.files/env.out` |
| checkout deliverable | `lib/ScoutCoder/path_kinds.rb` 869 lines, md5 `2739261544bc2b4c5f37b3d9ef2b6135` (`entity` block starts L314, `entity_property` L495) | `tmp/path_kinds/round7/ops5a/out/engine-gate.txt` |
| `workflow.rb` | 1,157 B, mtime 10-10 13:05 — **unchanged by round 7** (predates the implementation); contains only the round-5/6 wiring: `require_relative 'lib/ScoutCoder/path_kinds'` at L22 consumed by `integrate_workflow_path_kinds(ScoutCoder)` | `tmp/path_kinds/round7/ops5b/out/ord_c4.txt` (size/no-scratch assertion); `~/.scout/tmp/notes/round7-inventory.md` §4 (see the note in the evidence index) |

Baseline suites, all fresh, all exit 0, byte-identical totals to round 6:

- path engine family (7 files): **189 tests, 641 assertions, 0 failures**
  (61/230 + 41/113 + 11/65 + 25/54 + 11/32 + 19/79 + 21/68) —
  `tmp/notes/round7-baseline.files/path_suite_test_path*.{out,err,exit}`;
- sandbox suite: **11 tests, 34 assertions** — `sandbox_suite.*`;
- round-5/6 probe matrix (harness layout): **PASS=101 FAIL=0** —
  `probe_matrix.*`; the flat-copy layout fails (87/87 with
  `probe_06_path_kinds.rb` dying on `cannot load such file -- test_helper`),
  recorded in `tmp/path_kinds/round7/baseline/probe_matrix-attempt1-wronglayout/`.

Checkout version control: **git metadata is broken in this checkout** — `.git`
is a gitfile pointing at the missing `../.git/modules/ScoutCoder`, so
`git status --porcelain` exits 128. Every change-set statement in this note
rests on direct filesystem evidence (md5s, mtimes, full-tree snapshots), not
git (`tmp/notes/round7-baseline.files/scoutcoder_git_forensics.out`). Nothing
was committed anywhere; the reference trees stayed clean throughout.

## Conventions

> **These locations were DERIVED by the round-7 execution, not specified by
> the user. They are flagged for user confirmation. The project-side paired
> test paths have NO on-disk precedent in this checkout and are flagged
> hardest.**

| artifact | tmp location (draft) | project location (promoted) |
|---|---|---|
| entity module | `share/entities/<entity>.rb` | `lib/ScoutCoder/entity/<entity>.rb` |
| entity property | `share/entity_properties/<entity>/<property>.rb` | `lib/ScoutCoder/entity/<entity>/<property>.rb` |
| paired test (entity) | `share/test/entity/<entity>.rb` | `test/ScoutCoder/entity/test_<entity>.rb` |
| paired test (property) | `share/test/entity_property/<entity>/<entity>.<property>.rb` | `test/ScoutCoder/entity/test_<entity>_<property>.rb` |

Derivation and confidence:

- The **tmp roots** are exactly what scout-gear's LiveWorkflow loads
  (`scout/workflow/live.rb:4` `SHARE_SUBDIRS`, entities before
  entity_properties, recursive sorted glob) and what the shipped
  `define_entity`/`define_entity_property` generators write
  (`lib/ScoutCoder/tasks/entity_tools.rb:26-28`). High confidence.
- The **project root** `lib/ScoutCoder/entity/` follows the README's layout
  contract (README "Layout conventions") and is SHARED by both kinds — flat
  `<entity>.rb` files and nested `<entity>/<property>.rb` subdirectories under
  one root. High confidence for the root; the sharing has a recorded
  consequence (F8).
- The **tmp paired-test** names are the round-1 convention
  (`research/path-kinds-task-entity-property.md`), reused by decision 4.
  Note the property test carries NO `test_` prefix tmp-side.
- The **project paired-test** paths
  (`test/ScoutCoder/entity/test_<entity>.rb`,
  `test/ScoutCoder/entity/test_<entity>_<property>.rb`) mirror the task-kind
  pattern (`share/test/task/<name>.rb` → `test/ScoutCoder/tasks/test_<name>.rb`)
  onto the entity nesting, with a FLATTENED property name. **No file has ever
  existed at these paths** — the shipped test tree holds only
  `test/ScoutCoder/tasks/` plus three support tests. The flattening choice
  (`test_<e>_<p>.rb` vs a nested `test_<e>/<p>.rb`) is explicitly open
  (`tmp/notes/round7-ops5b.md` §8 flag 1; scope memo §4.2). **Needs user
  confirmation.**

**Identifier TSV side files are OUT of scope for round 7, by decision.** They
live at `share/entity/<entity>.identifiers.tsv` (README layout; the generated
`add_identifiers` path is relative to the entity file,
`entity_tools.rb:175`), i.e. OUTSIDE both kind roots. Pulling them in means a
third location/root per kind, which would hit the documented `path_list`
KeyError fragility for a declared location without a root (path.rb:1104-1107,
round-1 H-A) and the round-6 trust-boundary precedent against out-of-root
writes. They are data, not code, already served by `define_entity`. Revisit
only on explicit user request (`tmp/notes/round7-scope.md` decision 3).

## Kind-definition recipe

What a new kind needs in `lib/ScoutCoder/path_kinds.rb` (all fields of the
two round-7 kinds are live examples at L314 and L495):

1. **A new entry in `ScoutCoder::PATH_KINDS`** with `description`,
   `locations` (e.g. `['tmp','project']`), `default_location` (must be a
   declared location — engine-enforced), and `roots` mapping each location to
   an **absolute** path. Relative roots fail closed at operation time with
   `Path sandbox requires absolute filesystem paths` (path.rb:219, 878-886;
   round-6 `malicious.txt`).
2. **`sandbox: true`** — the flag is the actual gate. With `sandbox: false`
   the very same traversal write that is denied under `sandbox: true`
   (`Path access denied by sandbox (unresolvable)`) escapes and creates a
   file outside the root; proven both ways for both kinds
   (`tmp/path_kinds/round7/containment/out/sandbox_flag.txt`, 9/9, including
   the scratch-agent registry-isolation check).
3. **`capabilities`** hash: for the entity kinds
   read/write/edit/list/move/rename/delete/validate/test/promote/smoke all
   true, `patch` false (whole-file authored sources). The tool surface stays
   the 12 generic `path_*` tools; there is no per-kind tool fan-out
   (`register_smoke_final.txt` a0-a12).
4. **Operation lambdas** (`validate`, `test`, `smoke`): 4-arg
   `->(agent, path, location, args)`, the engine's custom-op dispatch
   contract (path.rb:1279-1299). Honest engine limit: the tool schema for
   `validate`/`test` has an EMPTY parameters branch — the comment at
   path.rb:770-772 ("Kind-specific operations may extend this schema…") has
   no consuming code path, and `additionalProperties: false` (path.rb:804)
   means extra args reach hooks only through direct dispatch. This was
   re-verified in round 7 (scope memo C6); unchanged from round 6.
5. **Declarative promotion**: `promotion_destination => 'project'` (a String,
   or a Hash with `"location"` and optional `"path"`; the move is
   path-preserving, path.rb:1213-1222). A Callable destination is
   structurally impossible (path.rb:1215-1217). The engine authorizes BOTH
   endpoints, defaults to no-clobber with `overwrite` opt-in (path.rb:1241),
   and performs the move itself.
6. **`promotion_post_move` hook**: optional 4-arg lambda
   `(agent, path, location, args)` fired AFTER the engine move, with the
   authorized endpoints merged into `args`. In this checkout it relocates the
   paired test (`entity`: `share/test/entity/<name>.rb` →
   `test/ScoutCoder/entity/test_<name>.rb`, path_kinds.rb:464;
   `entity_property`: nested tmp test → flattened project test, path_kinds.rb:665).
   **Honest note: the hook is TRUSTED-PLUGIN behavior, never an
   engine-authorized endpoint.** `path_authorize!` on the paired-test
   destination is DENIED (`outside_grants`) while the primary destination is
   ALLOWED — recorded directly in
   `tmp/path_kinds/round7/regression/out/mechanics_probe.txt`. No statement
   anywhere in this note should be read as "the engine moved the paired
   test".
7. **Wiring**: no `workflow.rb` change is needed to REGISTER a new kind —
   `workflow.rb:22` already requires `lib/ScoutCoder/path_kinds` and
   `integrate_workflow_path_kinds(ScoutCoder)` consumes the constant; round 7
   added two kinds with `workflow.rb` byte-untouched. Registration collision
   is engine-enforced on kind NAME + source workflow: a foreign workflow
   re-supplying `task` raises `ParameterException` naming both workflows
   (path/workflow_kinds.rb:48-52; `register_smoke_final.txt` e1-e4). Kinds
   travel only with the whole-workflow `tool: ScoutCoder` line; a task-level
   tool line registers no kinds (c1-c2).

## Findings

**F1 — C1: the README's claimed `workflow.rb` lib-entity loader does NOT
exist.** README "Layout conventions" says workflow.rb "loads this checkout's
built-in entity definitions from `lib/ScoutCoder/entity/*.rb` … and finally
the built-in entity property files". The code is absent: workflow.rb (33
lines, read in full) has no such requires, and the directory does not exist.
Consequence, demonstrated twice independently: a promoted entity file is NOT
loaded by `require './workflow'` (module ABSENT in a fresh process) —
`tmp/path_kinds/round7/regression/out/wiring_probe.txt` and
`tmp/path_kinds/round7/ops5b/out/ord_c4.txt`. Promotion is a pure file move;
registration is wiring, and wiring is a deliberate `workflow.rb` source edit
the user has not made. (Recorded here, not fixed in the README — user
decides. Scope memo §3 C1, decision 6.)

**F2 — C2: "re-extending `Entity` resets property metadata" is inaccurate
for current scout-gear.** scout-gear `scout/entity.rb:13` guards with
`unless base.instance_variables.include?(:@properties)`; fresh-process probes
A/D/E/F/G (scope memo §1) show the `@properties` hash (same object_id), its
keys, block parameters and `all_properties` all survive re-extension, for
both `Entity` and `EntityWorkflow` bases. The REAL wrong-order failure mode
is a loud load failure: a property file whose module has not yet extended
Entity raises `NoMethodError: undefined method 'property'`, which
LiveWorkflow wraps in a ScoutException naming the file (live.rb:34-35) —
it does NOT silently unregister. Corroborating: the checkout's own
`test/ScoutCoder/test_LiveWorkflow.rb` has ONE pre-existing failure,
`test_entities_load_before_entity_properties`, which asserts the old
(silent-unregistration) belief; it was reproduced with the PRE-STEP
path_kinds.rb restored, so it is independent of round 7
(`tmp/notes/round7-register.md` §3). (Recorded, not fixed — user decides.)

**F3 — API drift in the round-1 drafts (all re-verified against current
source this round).** (a) The drafts' custom promote lambdas that perform the
move themselves are obsolete: promotion is now declarative and
engine-controlled (path.rb:1213-1248; scope C5). (b) `smoke` IS a real engine
capability now (`DEFAULT_CAPABILITIES`, path.rb:41) — the round-1 note's "no
smoke operation exists" is false, and both new kinds implement it (C3).
(c) Roots must be absolute (path.rb:219/878-886). (d) The authoring envelope
is TOP-LEVEL modules (`module <CamelCase>`), not the drafts'
workflow-namespaced `module TestWF` nesting — LiveWorkflow `Kernel#load`s
drafts at top level (live.rb:33) and the shipped generators emit top-level
modules (entity_tools.rb:172-193; scope C4). (e) Custom ops dispatch as
4-arg `implementation.call(self, path, location, args)` (path.rb:1293-1297).

**F4 — The entity-before-property ordering contract fails LOUDLY, and the
raw exception differs by load path.** Property promoted while its entity is
still a tmp draft: files land split (entity loaded by LiveWorkflow, property
not — no loader), 3/3 (`ord_c1.txt`). Both promoted and loaded in order:
loads and dispatches (`R7cEnt.setup('smoke-id', …).label('a-','-b')` →
`a-smoke-id-b`) (`ord_c2.txt`). Property loaded before entity: hard failure,
with the discriminating control (same files, reversed order, clean load)
passing — the failure is ORDER, not content (`ord_c3.txt`, 2/2). Honest
nuance: a DIRECT `Kernel#load` of the property raises the RAW `NoMethodError`
(not the ScoutException), because live.rb's wrapper only covers
LiveWorkflow-loaded files (`ord_c1.txt`; ops5b §4 C1). Both orderings are now
pinned by permanent fresh-process tests
(`test/ScoutCoder/test_path_kinds.rb`:
`test_property_before_entity_load_fails_loudly_in_fresh_process`,
`test_entity_then_property_loads_and_dispatches_in_fresh_process`).

**F5 — Promotion never evaluates content; there is no content gate on
promote.** A property whose body shells out, uses backticks and writes a
marker at load time, and an entity extending the wrong base, were both
promoted VERBATIM (bytes preserved, `moved_verbatim=true`, marker file never
created — no `load`/`eval` anywhere on the promote path):
`ops5b/out/ent_malicious.txt` (3/3), `ep_malicious.txt` (2/2). Escalation-
worthy finding: none. Residual risk, stated honestly: NOTHING on the promote
path gates content quality, so a malicious draft lands at
`lib/ScoutCoder/entity/` silently. Safe today precisely because nothing loads
that tree (F1); it becomes load-bearing the moment wiring lands. Mitigation
is workflow-level (validate/test/smoke are caller-invoked separate ops).

**F6 — Containment holds for both kinds, with byte-identical outside-root
canaries.** 14 recorded check rows across both kinds, all pass: absolute-path
writes 20/20, integrity 7/7, promote-cross 8/8, symlink-dir 6/6, symlink-in
4/4, symlink-out 8/8, traversal 25/25, with `canary_verifications` counts
proving the outside-root canaries (absolute in `/tmp`, relative outside the
checkout) stayed byte-identical (`containment/out/MATRIX.txt` +
`containment/canary.rb`). `sandbox_flag.txt` 9/9 adds the discriminating
pair: same traversal write DENIED under `sandbox: true`, EXECUTED under
`sandbox: false` (with cleanup and registry isolation).

**F7 — The hook side-effect surface is exactly one path per promotion.**
Full-checkout `find`+sha256 snapshots before/after each promote
(`ops5b/out/snapshots/`): D1 (entity + paired test) — added exactly
`[lib/ScoutCoder/entity/<e>.rb, test/ScoutCoder/entity/test_<e>.rb]`, removed
exactly the two tmp-side files; an un-promoted sibling entity and its test
untouched. D2 (no paired test) — only the engine pair, hook contributed
nothing and created no directory. D3 (property + test) — only the property's
own nested paths moved. Hook contract behaviors pinned: fires only when the
tmp test exists; no-clobber by default (`post_move: "skipped"` with reason,
both files untouched); `overwrite: true` relocates byte-identically;
idempotent on re-run (`ent_/ep_hook-idempotent`). The trust boundary itself
(engine authorizes only the primary pair; the paired-test destination is
DENIED by `path_authorize!`) is recorded in
`regression/out/mechanics_probe.txt` and pinned permanently by
`test_engine_authorized_set_excludes_paired_test_destination`.

**F8 — Shared project root + nested virtual paths: the real semantic
differences from the task kind** (`tmp/notes/round7-lifecycle.md` §"Semantic
differences"). (a) Because the engine listing globs the whole root
(path.rb:1104-1113), a project draft of ONE kind is visible in the OTHER
kind's project listing (tmp roots stay separate, so tmp isolation holds) —
by-design consequence of mapping both kinds to `lib/ScoutCoder/entity/`,
recorded PASS-with-note. (b) Nested virtual paths behave as directories:
parents auto-created, list-prefix semantics, cross-entity-dir rename acts as
a move. (c) Empty parent directories are NOT reclaimed by the engine after
deleting the last property; consumers must prune or tolerate. (d) Engine
parity items re-confirmed for both kinds: rename/move onto an existing name
silently overwrites (no no-clobber, unlike promote); move of a missing source
surfaces a raw unrescued `Errno::ENOENT`; unsupported location and
nonexistent-path denials return the documented envelopes.

**F9 — Validate/test/smoke are real, and the probes forced four code
fixes** (`tmp/notes/round7-ops5a.md` §"Changes"). Validate: AST syntax gate
plus declaration checks — entity needs a top-level `module <CamelCase(file)>`
with `extend Entity|EntityWorkflow` (reports WHICH base); property needs
`module <CamelCase(entity SEGMENT)>` + `property :name => :type` and NO
extend line; flat paths rejected. Test: writes the paired Test::Unit file,
runs it in a fresh process; pass AND deliberately-failing runs recorded for
both kinds. Smoke: a real fresh-process Scout execution — entity registers
(`SMOKE_OK entity=R7Probe modules=2`; EntityWorkflow variant `modules=3`);
property registers AND DISPATCHES on a synthetic entity
(`SMOKE_OK entity=R7Probe property=label value="smoke-id"`). Fixes forced by
probes: (1) the generated test's `$LOAD_PATH.unshift` line was emitted as a
literal `#$LOAD_PATH` comment (heredoc escape bug) so tests silently ran
against the INSTALLED Scout; (2) smoke originally passed a raising property
GREEN because it only checked registration — now performs a real dispatch;
(3) the property module-name check must derive from the entity SEGMENT, not
the property file name; (4) a typeless `property :plain do` is a legal Scout
declaration (defaults `:both`) and must not be a validate error.

**F10 — Two-name addressing is a trap the flat task kind cannot have.**
Entity and property drafts carry a file name AND an implicit module name
(CamelCase of the entity segment); validate must keep them consistent, and
the property kind derives the required module from the PATH SEGMENT
(`r7_notype/plain.rb` required `R7Notype`, not `R7NoType` — the probe that
caught the wrong derivation, F9.3).

**F11 — Engine-API facts learned while probing** (`tmp/notes/round7-register.md`
§4): `ParameterException` is a TOP-LEVEL constant (not `Scout::…`); the
offline mock endpoint resolves through `Path.path_maps` with the probe dir
prepended WITHOUT an `etc` segment (the first failed attempt is preserved in
`register/out/register_smoke.err`). No other discrepancies: registration
signature, normalization, declarative promotion, incorporation and collision
all matched the memo citations.

**F12 — Permanent tests confine the production hooks without any engine or
production-code refactor.** The production hook lambdas resolve
`ScoutCoder::PATH_KIND_ROOT` at CALL time (lexical scope, not a captured
value), so `test/ScoutCoder/test_path_kinds.rb` swaps the constant to a
`Dir.mktmpdir` sandbox and registers a COPY of the production kind — proven
sound by `regression/out/const_swap_probe.txt`: the registered copy's hook is
the IDENTICAL object (`equal? == true`) and all its writes land inside the
sandbox while the real tree stays untouched. Honest limit: the
trust-boundary test cannot observe the PRODUCTION kind's "hook disabled"
behavior without engine changes — it exercises a hookless COPY on a scratch
agent (`mechanics_probe.txt`) and asserts the production hook's effects
(sandboxed) instead; this is a recorded limitation, not an overclaim.

**F13 — Round-7 file-set end state.** Permanent deliverables:
`lib/ScoutCoder/path_kinds.rb` (869 lines, three kinds), and
`test/ScoutCoder/test_path_kinds.rb` (10 tests / 56 assertions, green in two
consecutive fresh runs — `regression/out/run1.txt`, `run2.txt`; 5
hook-surface, 2 trust-boundary, 2 ordering, 1 mechanics-control). All six
probe-created directories are absent from the tree (teardown proofs:
`lifecycle/post_cleanup_listing.txt`, `ops5a/out/post-cleanup-share.txt`,
`ops5b/out/snapshots/post-all.snap.txt` = zero file lines vs `pre` snapshot,
`containment/out/post_cleanup_listing.txt`); no promoted entity/property
artifact survives on disk — promotion behavior is evidenced only by the
recorded streams and snapshots.

One post-inventory stray, recorded as found and deliberately left untouched:
`share/entities/workflow_entity_probe_4_2a7106.rb` (104 B, mtime 10-11
00:53). It appeared AFTER the leftover inventory was written (which found
`share/entities/` empty at 00:25), during the regression step's window, and
its name matches the pattern `workflow_entity_probe_<pid>_<hex>` used by the
pre-existing `test/ScoutCoder/tasks/test_entity_tools.rb`
`test_entity_workflow_base_is_opt_in_and_not_double_extended`; the trailing
`4` is consistent with a bwrap-isolated pid. That test's ensure-clause
deletes a `tmp/workflows/TestWF/...` path, not this one, so a run whose
define_entity landed in the checkout root would leave exactly this file.
Recorded here for the user to sweep; not deleted and not diagnosed further
(consolidation-only step).

## Evidence index

Claim → recorded output (all paths relative to the checkout
`/bulk/mvazque2/git/AgentSuite/ScoutCoder`; `.txt` files carry command, pwd,
engine md5 gate, output; `.exit` the status):

| # | claim | evidence |
|---|---|---|
| 1 | engine path.rb md5 unchanged start-to-end (drift gate) | header of every `tmp/path_kinds/round7/*/out/*.txt`; `tmp/notes/round7-baseline.md` §A |
| 2 | scout-ai HEAD b504275d / scout-gear 23c5b1f, porcelain clean | `tmp/path_kinds/round7/baseline/pins.txt` (HEADs + porcelain both trees); `tmp/notes/round7-baseline.files/post_run_recheck.out`; `tmp/path_kinds/round7/containment/out/post_cleanup_listing.txt` |
| 3 | baseline suites 189/641, 11/34, 101/101 (fresh, exit 0) | `tmp/notes/round7-baseline.files/path_suite_test_path*.{out,err,exit}` (re-run appendix), first-run originals `tmp/path_kinds/round7/baseline/scout_ai_test_path*` / `scout_ai_path_suite*` / `scout_ai_sandbox_suite*` / `probe_matrix*` |
| 4 | flat-copy probe-matrix layout fails (wrong layout recorded, not repaired) | `tmp/path_kinds/round7/baseline/probe_matrix-attempt1-wronglayout/` |
| 5 | checkout git metadata broken (gitfile → missing module dir) | `tmp/notes/round7-baseline.files/scoutcoder_git_forensics.out` |
| 6 | both kinds registered, both routes, idempotent, collision raises — 31/31 | `tmp/path_kinds/round7/register/out/register_smoke_final.txt` (exit 0) |
| 7 | task kind untouched by round 7 | `tmp/path_kinds/round7/register/out/task_regression.txt` (exit 0) + pre-step backup `register/path_kinds.before.rb` |
| 8 | lifecycle matrix 81/81, 0 FAIL (15 checks × 2 kinds) | `tmp/path_kinds/round7/lifecycle/MATRIX.txt` + 30 triplets in `lifecycle/out/` |
| 9 | shared-project-root listing cross-visibility; nested-path dir semantics; empty-parent leftovers | `lifecycle/out/{entity,entity_property}_isolation.txt`, `*_delete-project.txt`, `*_write.txt` |
| 10 | validate/test/smoke ops — 16 checks, 33/33 assertions | `tmp/path_kinds/round7/ops5a/out/` (48 streams: `ent_/ep_ × validate-{positive,negative}, test-{pass,fail,missing}, smoke-{positive,broken,missing}`) |
| 11 | test op shows PASS and deliberately-FAILING runs | `ops5a/out/ent_test-fail.txt`, `ep_test-fail.txt` (real Test::Unit failure output, exit 1 inside the probe, probe exit 0) |
| 12 | smoke = real fresh-process registration/dispatch | `ops5a/out/ent_smoke-positive.txt` (`SMOKE_OK entity=R7Probe modules=2`, `R7Ew modules=3`), `ep_smoke-positive.txt` (`SMOKE_OK … value="smoke-id"`) |
| 13 | promote matrix B1–B8 both kinds (success, relocate, absent, no-clobber, overwrite, fail-source-intact, malicious, idempotent) | `ops5b/out/ent_*.txt`, `ep_*.txt` (20 check triplets = 60 stream files, exit 0, incl. the `nonexistent` and `project-source` checks) |
| 14 | promotion never evaluates content (malicious B6) | `ops5b/out/ent_malicious.txt` (3/3), `ep_malicious.txt` (2/2) |
| 15 | ordering c1–c4 incl. the wiring verdict | `ops5b/out/ord_c1.txt` … `ord_c4.txt` |
| 16 | hook side-effect surface exactly one path (D1–D3) | `ops5b/out/trust_d.txt` (5/5) + `ops5b/out/snapshots/{pre,d1-,d2-,d3-}{before,after}.snap.txt` |
| 17 | containment 14 rows + canary byte-identity | `containment/out/MATRIX.txt` + `containment/canary.rb` |
| 18 | `sandbox: true` flag is the gate (denied vs executed) | `containment/out/sandbox_flag.txt` (9/9) |
| 19 | clean-tree teardown, all six probe dirs absent | `lifecycle/post_cleanup_listing.txt`; `ops5a/out/post-cleanup-share.txt`; `ops5b/out/snapshots/post-all.snap.txt`; `containment/out/post_cleanup_listing.txt` |
| 20 | permanent suite 10 tests / 56 assertions, stable ×2 | `regression/out/run1.txt`, `run2.txt` (exit 0 both) |
| 21 | const-swap feasibility (hook identical object, sandboxed writes) | `regression/out/const_swap_probe.txt` |
| 22 | trust boundary: `path_authorize!` DENIES paired-test destination, ALLOWS primary | `regression/out/mechanics_probe.txt` |
| 23 | promoted file NOT loaded by `./workflow` (independent re-demonstration) | `regression/out/wiring_probe.txt`; `ops5b/out/ord_c4.txt` |
| 24 | F1/C1: no lib-entity loader in workflow.rb | `workflow.rb` itself (33 lines, grep 0 hits); #23 evidence; `tmp/notes/round7-scope.md` §3 C1 |
| 25 | F2/C2: re-extension preserves metadata (probes A–G), real failure is loud | `tmp/notes/round7-scope.md` §1 Loader; `tmp/notes/round7-register.md` §3 (pre-existing test_LiveWorkflow failure reproduced pre-step) |
| 26 | API drift of round-1 drafts (F3) | `tmp/notes/round7-scope.md` §3 C3–C6 + §1 engine citations |
| 27 | engine-API discrepancies found while probing (F11) | `tmp/notes/round7-register.md` §4; failed first attempt preserved at `register/out/register_smoke.err` |
| 28 | path_kinds.rb identity 273926… (post-ops5a, unchanged through end) | `ops5a/out/engine-gate.txt`; `containment/out/post_cleanup_listing.txt` |
| 29 | derived conventions + open questions (decisions 1–6, flags) | `tmp/notes/round7-scope.md` §2/§4; `tmp/notes/round7-ops5b.md` §8 |
| 30 | full leftover inventory (this round's map) | `~/.scout/tmp/notes/round7-inventory.md` — NOTE: this inventory landed OUTSIDE the checkout due to the write-tool sandbox-PWD quirk (see the experience report); its contents are mirrored by indexes 1–29 plus the step memos |
| 31 | **superseded, not failures**: 7 mid-run debug recordings exit 1 | `lifecycle/out/dbg_{entity,ep}_{test-pass,smoke-broken,validate-*}.txt` and `dbg2_ep_validate-positive.txt` (exit 1 each) — early runs of what became the ops5a checks; final non-prefixed entries are exit 0 and feed the matrices |
| 32 | **superseded, not failures**: record.sh wrapper hiccup exit 126 | `register/out/ruby.{err,exit}` (126, "Permission denied" invoking task_regression.rb through the wrapper); the probe's recorded successful run is `register/out/task_regression.txt` (exit 0) |
| 33 | post-inventory stray `share/entities/workflow_entity_probe_4_2a7106.rb` (found during consolidation, not removed) | the file itself (104 B, mtime 10-11 00:53); `~/.scout/tmp/notes/round7-inventory.md` §6 (share/entities empty at 00:25); name-pattern source `test/ScoutCoder/tasks/test_entity_tools.rb` L133-156 |

## Cross-kind comparison matrix

Factual rows only (the comparative verdict belongs to the final report):

| dimension | `task` (round 5/6) | `entity` (round 7) | `entity_property` (round 7) |
|---|---|---|---|
| tmp root | `share/tasks` | `share/entities` | `share/entity_properties` |
| project root | `lib/ScoutCoder/tasks` | `lib/ScoutCoder/entity` | `lib/ScoutCoder/entity` (SHARED with `entity`) |
| virtual path shape | flat `<name>.rb` | flat `<entity>.rb` | nested `<entity>/<property>.rb` |
| envelope validation | `module ScoutCoder` wrapper + task declaration | top-level `module <CamelCase(file)>` + `extend Entity|EntityWorkflow` | top-level `module <CamelCase(entity segment)>` + `property` declaration; extend line FORBIDDEN |
| two-name addressing | no (one identifier) | yes (file name ↔ module name) | yes (path segment ↔ module name; file name is the property) |
| paired test (tmp) | `share/test/task/<name>.rb` | `share/test/entity/<name>.rb` | `share/test/entity_property/<e>/<e>.<p>.rb` (nested, no prefix) |
| paired test (project) | `test/ScoutCoder/tasks/test_<name>.rb` (precedent on disk) | `test/ScoutCoder/entity/test_<name>.rb` (NO on-disk precedent) | `test/ScoutCoder/entity/test_<e>_<p>.rb` (NO on-disk precedent; flattened) |
| paired-test relocation on promote | hook, yes | hook, yes | hook, yes |
| engine-authorized set | primary source + destination only | same | same |
| wiring requirement after promote | explicit require in `workflow.rb` (precedent: `hello_r5` at workflow.rb:31) | no loader exists — deliberate `workflow.rb` edit required (F1) | same, plus ordering (below) |
| ordering constraint | none | entity must load before its properties (loud failure otherwise) | same constraint, keyed on the entity segment |
| promote semantics | declarative, path-preserving, no-clobber default, overwrite opt-in | identical | identical |
| smoke semantics | task runs and prints | module resolves, base extended, registers in `Entity::MODULES` | registers AND dispatches on a synthetic entity (stronger than `task`) |
| registration route | LiveWorkflow `Kernel#load` of `share/tasks` | LiveWorkflow of `share/entities` | LiveWorkflow of `share/entity_properties` |
| project-listing isolation | isolated (own root) | cross-visible with `entity_property` (shared root) | cross-visible with `entity` (shared root) |
| broken-draft blast radius | that task unavailable | poisons the workflow load of every later fresh process (LiveWorkflow loads all drafts) | same |

## Open items carried to the user (not resolved here)

1. Wiring shape for `lib/ScoutCoder/entity/**` (F1; ord_c4 records the exact
   two-glob require loop that would work — entities first, then nested
   properties).
2. Confirmation of the derived project-side paired-test paths, especially the
   flattening choice (Conventions).
3. README C1/C2 corrections (F1, F2) — recorded here, deliberately not
   applied.
4. Pre-existing `test_LiveWorkflow` failure encoding the C2 belief (F2).
5. Identifier TSV side files out of scope (Conventions).
