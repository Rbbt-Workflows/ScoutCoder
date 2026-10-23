# Path kinds round 12 — the `probe` kind, `ProbeSupport`, and `run_probe`

Round 12 of the incremental path-kinds implementation (rounds 6–10 built
the four Ruby kinds and hardened `test_file`/`run_test`; round 11 added
`python_task` and the Python test tier). This round added a sixth kind,
`probe`: unsandboxed, ScoutCoder-only Ruby snippets for investigating the
Scout framework itself, executed through a dedicated `run_probe` custom
operation. The round began with a bounded engine-contract investigation
whose outcome (C) forced a deliberate design deviation from the original
ask; that deviation is §b of this note and is the number-one item the
user must ratify. A full README sweep (dead-tool pruning plus probe
documentation) closed the round. This note is the durable record.

**Nothing is committed anywhere.** All work is uncommitted working-tree
state in `/bulk/mvazque2/git/AgentSuite/ScoutCoder`. The runtime engine
checkout `/bulk/mvazque2/git/scout-ai` was read (fingerprints, source
frames) and never patched.

## a. Summary

1. **Engine-contract investigation, outcome C.** Neither `path_write`
   nor `path_edit` can carry a kind-handler payload through to the agent:
   write ignores kind overrides entirely (DC-1) and edit consults them
   only as a `:content` transform with a fixed result shape (DC-2). The
   pre-agreed decision rule therefore applies: no auto-run this round;
   ship `run_probe` only; record engine defect candidates.
2. **New kind `probe`** — one-root (`share/probes/`), promote-less,
   validate-only (syntax, never executes), plus ONE custom operation
   `run` exposed as the `run_probe` tool — the two-surface channel
   `run_test` already uses.
3. **`ProbeSupport`** — fresh UNSANDBOXED Ruby child per run: preloads
   the owning checkout's `workflow.rb`, process-group +
   TERM/10s-grace/KILL discipline, per-probe timeout 1..3600 s (default
   120), AST-only syntax gate before execution, saved/syntax/execution
   reported as independent outcomes, failures normalized to Scout
   exceptions or structured envelopes.
4. **Create-and-run in one call** — `run_probe`'s optional `source`
   input writes/overwrites the probe file, syntax-checks it, and
   executes it, reporting all three stages independently; a runtime
   failure never reverts or deletes the saved source.
5. **Motivating case proven** — a probe child reads
   `/bulk/mvazque2/git/scout-ai/tmp/path_baseline.txt` (127 874 bytes,
   md5 `403d5f34`), a path under no Workspace sandbox grant for this
   agent, completing with `exit_class=completed`
   (`motivating-run.json`).
6. **README sweep** — 8 dead tool entries removed with entangled prose;
   19 tools kept and re-verified live; probe documentation added
   throughout; a third tool state (imported but unexported) discovered
   and recorded.
7. **Suite state** — 136 tests / 6 F / 3 E (9 F/E), every one
   file+test-identical to the recorded baseline fingerprint; pin test
   green at the six-kind set.

## b. The outcome-C deviation, stated plainly

The round-12 ask was **auto-run**: writing or editing a probe through the
generic `path_*` tools would execute it. The engine cannot express that:

- **DC-1** — `path_write` never consults the kind's operation table. An
  `overrides['write']` registration is accepted and normalized into the
  table, but no write code path reads it: with the override declared,
  the event log stays empty, the file still appears engine-written, and
  the tool result is the fixed shape `{doc_id, kind, path, location,
  target_file, written}` — no handler key anywhere
  (`a1_write_override.json`, `override_fired: false`; control
  `a2_default_write.json`; source verdict
  `engine_source_frames.out` → `write consults operation_table: false`).
- **DC-2** — `path_edit` consults an override only as a `:content`
  transform: the handler receives `(content, args)`, its String return
  becomes the new content (replacing, not complementing, the requested
  selector edit), and the tool result is the fixed `{doc_id, kind, path,
  changed, content}` — no extra key can surface
  (`b1_edit_override.json`). A `:full`-typed edit override is invoked
  with content arity and raises raw `ArgumentError` at
  `path.rb:1243 path_apply_content_handler` (`b4_edit_full_type_arity.json`);
  an override returning a Hash raises `NoMethodError` at `path.rb:1246`
  and the raw non-Scout exception escapes the tool wrapper
  (`b3_edit_override_hash_return.json`). Plain edit fires no kind hook
  afterwards at all (`b2_post_edit_callbacks.json`,
  `events_after_edit: []`).

So the design deliberately does NOT fight the engine:

- The generic operations `path_write`, `path_edit`, `path_read`,
  `path_list`, `path_move`, `path_rename`, `path_delete` NEVER execute a
  probe — they are pure file operations over the kind root. This is
  pinned by `test_probe_generic_write_never_auto_runs` (canary absent
  after a plain write) and stated in the README's
  "Outcome-C deviation, stated plainly" block.
- **Create-and-run lives in the custom operation's `source` input** —
  the channel custom operations DO provide (payload returned verbatim,
  `a3_custom_operation_channel.json`; the same channel `run_test` uses).
  With `source`, the call saves first, syntax-checks, then executes,
  reporting `saved` (true/false plus physical target), `syntax_ok` (with
  `syntax_error` when false) and the `execution` block as INDEPENDENT
  outcomes. A syntax failure means saved-but-not-executed
  (`test_probe_syntax_failure_saves_but_skips_execution`); a runtime
  failure is reported (`exit_class=raised`, exception class and message,
  stderr, exit status) with the file still on disk
  (`test_probe_runtime_failure_keeps_source_and_reports_exception`).
- **If DC-1/DC-2 are ever fixed upstream**, auto-run-on-write can be
  revisited as a `:full` write override that saves first and attaches
  the execution report to its returned payload
  (`tmp/notes/round12-engine-contract.md`, Recommendation). Outcome C is
  the only blocker today.

This is the deviation the user must ratify (§l, item 1).

## c. Engine-contract findings and defect candidates

**Engine identity.** The runtime engine is the checkout
`/bulk/mvazque2/git/scout-ai`, NOT the installed gem: the run_test child
reported `path.rb:1357` (path_write) and `path/edit.rb:161` (path_edit)
with `path.rb md5=c1d9e3516c79174eb7a590f8408ee4ef` and
`edit.rb md5=947f32537340f4b0024b246fa3f72792`
(`engine_fingerprint.out`; unsandboxed confirmation
`engine_fingerprint_unsandboxed.out`). The Workspace-sandbox view of the
installed gem copy (`~/.rvm/gems/ruby-3.3.1/gems/scout-ai-2.1.0`, md5
`0d55806e…`) is an older spelling and a sandbox-visibility artifact, not
a stale-copy problem — the same engine pin round 11 recorded (§h there).
Any defect-candidate reference must cite the `/bulk` checkout.

**One-root promote-less kinds are fully supported** (question c,
green): a kind with exactly one location root (`tmp`), no `promote`
capability, `validate` on, registers cleanly — `path_kinds` lists it
with `locations: ["tmp"]`, capabilities honored verbatim
(`c1_one_root_no_promote.json`); an unknown explicit location is a clean
serialized error envelope, never a silent alias
(`c2_unknown_location.json`: `Location "project" is not supported by
path kind probe`); and the custom-operation channel works unchanged on
the single-location kind.

**Defect candidates (engine, NOT patched by convention).**

| id | finding | exact evidence |
|---|---|---|
| DC-1 | `overrides['write']` is silently dead: registration accepts it into the operation table, but `path_write` (`path.rb:1357` in the `/bulk` checkout) never consults the table. Either write should dispatch overrides like edit/patch, or registration should reject a write override. | `a1_write_override.json` (`override_fired: false`), `a2_default_write.json`, `engine_source_frames.out` |
| DC-2 | `path_edit` (`edit.rb:161`) ignores the override `type`: a `:full`-typed edit override is invoked with content arity `(content, args)` and raises raw `ArgumentError` at `path.rb:1243 path_apply_content_handler` before any write. | `b4_edit_full_type_arity.json` |
| DC-3 (minor, docs) | PathEngine.md does not state that write ignores overrides; §5–§6 imply overrides are honored per built-in operation. Amend when DC-1/DC-2 are decided. | PathEngine.md job `ScoutCoder/help_get_repo_document/Default_6a1e3abf85ff38298d600c530f88e702` |

**Raw-exception escape (surprise 3).** Non-Scout exceptions from
handlers escape the agent tool wrapper raw (observed at `b3`:
`NoMethodError` inside `path_apply_content_handler` surfaced unserialized).
Consequence for ScoutCoder: every handler must normalize its own
failures — `probe_support.rb` returns structured envelopes or raises
Scout `ParameterException` on every path, never a raw Ruby exception
(`test_probe_runtime_failure_keeps_source_and_reports_exception` proves
the envelope).

## d. Implementation map

| file | responsibility / key mechanics |
|---|---|
| `lib/ScoutCoder/probe_support.rb` (361 lines) | `ScoutCoder::ProbeSupport`. **Preload**: `run_for_agent_with_kind` resolves the child checkout (`child_checkout_for`: pinned `project_root` → `ScoutCoder.child_checkout` anchor chain → PATH_KIND_PROJECT_ROOT override → owner-of-resolved-file marker climb → pinned kind root → structural `PATH_KIND_ROOT`), then runs `ruby -e '$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow"; load ARGV.fetch(0)' <probe.rb>` from it. **Process discipline**: `run_child` spawns in its own process group; on timeout `Process.kill('TERM', -pid)`, `TERM_GRACE = 10` s of reaping, then `Process.kill('KILL', -pid)`. **Timeout envelope**: `MIN_TIMEOUT=1`, `MAX_TIMEOUT=3600`, `PROBE_TIMEOUT=120`; `normalize_timeout` rejects non-integers and out-of-range values as `ParameterException`. **Syntax gate**: `RubyVM::AbstractSyntaxTree.parse` (the same AST-only mechanism the task/python_task kinds use; `EntityDefinitionSupport.compile!` uses `Ripper.sexp` — either is side-effect-free) runs BEFORE execution; failure = saved-but-not-executed. **Classification**: `completed` / `raised` / `timeout` from status + timed-out flag. **Dispatched-kind seam**: the engine strips `kind` from custom-op `args` (`path_dispatch` deletes it), so `dispatch` derives the kind from the thread-local the operation wrapper sets, else `args['kind']` (task surface), else the resolved target's containing pinned root (`kind_for_target`, first registered kind wins) — the same seam round 11's test_file runner needed. |
| `lib/ScoutCoder/path_kinds/probe.rb` (169) | `PATH_KIND_PROBE_DEFINITION`: one location `tmp` at `Scout.share.probes`, name pattern `[a-z][a-z0-9_]*`, `.rb` extension omitted from the virtual path; capabilities read/write/edit/list/move/rename/delete + `validate` (NO smoke, NO promote); `validate` handler = name check + AST parse, never executes; `operations['run']` registered `:full` with `authorization: :read`, mirroring `run_test`'s registration shape. |
| `lib/ScoutCoder/path_kinds.rb` | aggregator requires `path_kinds/probe` and adds `'probe' => PATH_KIND_PROBE_DEFINITION` to `PATH_KINDS` (established load order). |
| `lib/ScoutCoder/tasks/probe_tools.rb` (34) | exported `run_probe` task: `path` (bare name, single-probe scope), optional `source` (create-and-run), optional `timeout_seconds`; desc states the unsandboxed trusted-code contract. |
| `workflow.rb` | one require line for `probe_tools`, after `test_runner_tools`. |
| `test/ScoutCoder/test_path_kinds.rb` | pin test at the six-kind set `%w[task entity entity_property python_task test_file probe]` + both custom-op tools; new `TestPathKindsProbe` class, 11 tests. |
| `share/test/integration/round12_outside_grant.rb` | integration draft: the motivating case, run in a fresh process; also drives the probe through the kind's own runner. |
| `share/probes/motivating_outside_grant.rb` | the motivating probe itself, kept as a reusable artifact. |

Conventions held from rounds 6–11 (no change): registration-time root
pinning; `.find(:current)`, never bare `.find`; smoke =
initialization-only (probe has none by design); promotion = one
resource, declarative destination (probe has none by design); generic
CRUD inherited from the engine with zero implicit execution. New this
round: the create-and-run `source` channel as the sanctioned
replacement for auto-run (§b), and the one-root promote-less kind shape
(proven by c1/c2) now in production use.

## e. Working recipe

Author, check, run a probe:

```bash
# 1. create-and-run in ONE call (outcome-C channel):
#    run_probe path=my_probe source='<ruby>'
#    -> saves share/probes/my_probe.rb, syntax-checks, executes,
#       reports saved/syntax/execution independently
# 2. static check only (never executes; canary-safe):
#    path_validate kind=probe path=my_probe
# 3. re-run the saved probe unchanged:
#    run_probe path=my_probe
# 4. with a timeout:
#    run_probe path=my_probe timeout_seconds=30
# (generic path_write/path_edit NEVER execute; path_promote is rejected
#  with "Path kind probe does not support promote")
```

Programmatic: `ScoutCoder.job(:run_probe, nil, path: 'my_probe').run` —
the motivating run's raw receipt is
`tmp/path_kinds/round12/motivating-run.json` (job reference
`ScoutCoder/run_probe/Default_5f97d4f…`, as recorded in
`tmp/path_kinds/round12/round12-implementation-report.md`; the job tree
itself is outside this checkout and not visible from the Workspace
sandbox — the persisted receipt is the durable evidence).

## f. README sweep

Evidence: `tmp/path_kinds/round12/readme-removal-ledger.md`
(re-verified NOW against a fresh `list_tasks` registry dump +
`workflow.rb` require/export greps, not from memory).

- **8 removed**: `define_task` (declaration fully commented out in
  `workflow_tools.rb`), `define_helper`, `author_task_test`,
  `run_task_test`, `author_helper_test`, `run_helper_test` (their two
  task files' `require_relative` lines are commented in `workflow.rb:31-32`),
  `define_entity`, `define_entity_property` (`#export_exec` at
  `entity_tools.rb:380/423` — see the third state below). Entangled
  prose swept: doctrine-table rows, "When to use which" generator
  paragraph, runner-choice list, authoring sections reoriented to
  `path_write kind=entity` / `kind=entity_property` with the
  complete-file format guidance kept intact. Four task-file comments
  that pointed at removed README entries updated to name successors
  (comment-only, no code deletion).
- **19 kept-and-verified live**: the six `help_*`, `document_task`,
  `list_tasks`, `task_inputs`, `task_code`, `task_dependencies`,
  `run_task`, `job_info`, `job_status`, `define_python_task` and
  `author_python_task_test` (SUPERSEDED markers kept), `list_entities`,
  `run_test`, plus the new `run_probe`.
- **Third state discovered**: `define_entity` / `define_entity_property`
  are imported AND callable (`ScoutCoder.job(:define_entity, ...)`
  works; its regression suite is green) but their `export_exec` lines
  are commented out, so agents never see them as tools. Removed from the
  README (which documents the agent-facing surface);
  `EntityDefinitionSupport` stays live code (`list_entities` consumes
  it). Whether to export or fully retire them is a user decision (§l).
- **`help_list_workflows` duplicated sentence — corrected in the Critic
  repair**: the duplicate "It is the discovery step for workflow
  names: …" lived in README.md (the `## help_list_workflows` entry,
  lines 1310-1311), not in `documentation.rb`'s `desc` as first
  recorded. It was in scope of the README sweep and the sweep missed it;
  the duplicate line was deleted (1310 kept, 1311 removed) in this
  round's repair bout. `documentation.rb` was verified clean.
- **`define_python_task` README fragment fixed**: the duplicated
  "inspection; the error identifies that state." sentence collapsed to
  one occurrence.
- **Probe documentation added**: kind-table row (one root, promote-less),
  six-kind capability paragraph, probe validate semantics, `### probe
  run_probe` subsection (mirroring `### test_file run_test`), trust
  boundaries bullet, doctrine-table row, `share/probes/` layout bullet,
  `# Tasks` `## run_probe` entry, and the outcome-C deviation block.
- **Anchor check**: all 44 README internal `](#…)` links resolve
  programmatically; grep for the eight dead names over README +
  `lib/ScoutCoder/path_kinds/*.rb` + `workflow.rb` returns zero
  documentation hits.

## g. Evidence index

Claim map: `tmp/notes/round12-claim-map.md` (README-bout statements,
each mapped to a `lib/` line, a green test, or a probe output; zero
unmappable). Source index for the engine-contract evidence:
`tmp/path_kinds/round12/README.md`.

| Claim | Evidence |
|---|---|
| Baseline recorded pre-change | `tmp/path_kinds/round12/baseline-full-suite.out`, `baseline-summary.md` (125 tests / 6 F / 3 E = 9 F/E fingerprint) |
| Implementation bout after-suite | `after-full-suite.out`, `after-summary.md` (136 / 6 / 3, same 9 F/E) |
| README bout after-suite | `readme-after-full-suite.out`, `readme-after-comparison.md` (again 136 / 6 / 3, same 9 F/E; pin green; anchors 44/44) |
| New tests green, fresh process | `new-tests.out` (11 probe tests + pin + integration draft) |
| Motivating case (outside-grant read) | `motivating-run.json` (raw `run_probe` receipt); tests in `share/test/integration/round12_outside_grant.rb` (fresh process, 1 test / 6 assertions, green) |
| DC-1 (write ignores overrides) | `a1_write_override.json`, `a2_default_write.json`, `engine_source_frames.out` |
| Custom-op payload channel works | `a3_custom_operation_channel.json` |
| DC-2 (:full edit arity crash; Hash-return crash; no post-edit hooks) | `b4_edit_full_type_arity.json`, `b3_edit_override_hash_return.json`, `b2_post_edit_callbacks.json`, `b1_edit_override.json` |
| One-root promote-less kind viable | `c1_one_root_no_promote.json`, `c2_unknown_location.json` |
| Engine identity (runtime = /bulk checkout) | `engine_fingerprint.out`, `engine_fingerprint_unsandboxed.out`, `engine_source_frames.out` |
| Engine-contract probe sources | `share/test/integration/round12_engine_contract.rb` (9 tests / 24 assertions, clean pass), `round12_engine_source_check.rb`, `round12_engine_fingerprint.rb`; reference copy `scratch_probe_test.rb`; drafting runner `runner.rb` |
| Validate never executes | `test_probe_validate_never_executes_valid_or_invalid` (canary absent for valid AND invalid sources) |
| Generic write never executes | `test_probe_generic_write_never_auto_runs` (canary absent after plain path_write) |
| Write-with-source independent outcomes | `test_probe_write_with_source_executes_and_reports_independently` |
| Runtime failure keeps source | `test_probe_runtime_failure_keeps_source_and_reports_exception` |
| Syntax failure saves but skips execution | `test_probe_syntax_failure_saves_but_skips_execution` |
| Path-only re-run repeats effect | `test_probe_rerun_of_unedited_probe_repeats_effect` |
| Timeout classification + bounds | `test_probe_timeout_classification`, `test_probe_timeout_bounds_rejected` |
| Child preloads owning workflow | `test_probe_child_preloads_owning_workflow` |
| Nothing auto-loads share/probes/ | `test_nothing_auto_loads_share_probes` |
| Six-kind lock + run_probe tool | `test_registered_kinds_match_readme_documented_set` |
| README removal ledger | `tmp/path_kinds/round12/readme-removal-ledger.md` |
| Implementation-bout report | `tmp/path_kinds/round12/round12-implementation-report.md` |
| Engine-contract final note | `tmp/notes/round12-engine-contract.md` |

## h. Reproduction commands

From the checkout root; every command a fresh process:

```bash
# full-suite enumeration (captures the 9 known F/E):
for f in $(find test -name 'test_*.rb' | sort); do
  echo "=== $f"; ruby -Itest "$f" 2>&1 | grep -E "Failure:|Error:|tests,"
done

# the probe tests alone:
ruby -Itest test/ScoutCoder/test_path_kinds.rb -v 2>&1 | grep test_probe

# motivating case through the kind's own runner:
ruby -Itest share/test/integration/round12_outside_grant.rb

# engine-contract probes (self-contained):
ruby -Itest share/test/integration/round12_engine_contract.rb

# create-and-run through the task surface:
scout workflow task ScoutCoder run_probe --path motivating_outside_grant

# engine pin:
md5sum /bulk/mvazque2/git/scout-ai/lib/scout/llm/agent/path.rb  # c1d9e351...
```

## i. Known-failure disposition (baseline fact stated exactly)

The round-12 brief said "expected: round-11 terminal state, 125 tests /
8 F/E — verify, don't assume". **Verified wrong: the actual recorded
baseline was 125 tests / 6 F / 3 E (9 F/E total)**, recorded before any
work (`baseline-summary.md`); the recorded numbers rule.

| run | tests | F | E | verdict |
|---|---|---|---|---|
| baseline (pre-change) | 125 | 6 | 3 | recorded as-is |
| after implementation bout | 136 | 6 | 3 | no failures beyond baseline-identical |
| after README bout | 136 | 6 | 3 | same |

All 9 F/E are file+test-identical across all three runs (the round-11
8-F/E drift plus `test_task_smoke_constructs_job_without_executing`,
which appeared new at the round-12 baseline). The only movement is +11
passing probe tests in `test_path_kinds.rb` (43→54).

## j. Engine identity pins across the round

| Point | `path.rb` md5 | `edit.rb` md5 | tree |
|---|---|---|---|
| Engine-contract bout (start/end) | `c1d9e351…` | `947f3253…` | `/bulk/mvazque2/git/scout-ai`, never modified |
| Implementation / README bouts | `c1d9e351…` | `947f3253…` | unchanged |

## k. Open items / next-round candidates

- **DC-1 upstream**: `overrides['write']` silently dead
  (`path.rb:1357` path_write; only `path_edit`/`path_patch` call
  `path_operation_implementation`). Either dispatch or reject at
  registration.
- **DC-2 upstream**: `path_edit` ignores the override `type`
  (`edit.rb:161`; arity crash at `path.rb:1243`). Related: an override
  returning a non-String raises at `path.rb:1246` AND the raw non-Scout
  exception escapes the tool wrapper.
- **DC-3**: PathEngine.md gap (§c table); amend when DC-1/DC-2 are
  decided.
- **Handler normalization burden**: because non-Scout exceptions escape
  raw (surprise 3), every future custom-operation handler must
  normalize its own failures the way `probe_support.rb` does. Worth an
  engine-side serialization fix rather than per-handler discipline.
- **`kind` stripped from custom-op args** (engine seam, also hit by
  round 11's test_file runner): handlers cannot see the dispatched kind
  from `args`; `ProbeSupport` works around it with a wrapper-set
  thread-local plus target-derived fallback. A stable engine contract
  here would remove the workaround.
- **`path_promote` failure-shape inconsistency**: with no promote
  capability the engine raises from `path_promote` itself as a JSON
  `{"exception": ...}` envelope ("Path kind probe does not support
  promote") rather than the `path_dispatch` spelling ("does not support
  operation …"); the promote-less test asserts both spellings.
- **AST message quirk**: `RubyVM::AbstractSyntaxTree` reports
  "unterminated string meets end of file" with no "syntax" token;
  syntax-failure assertions match `/syntax|unterminated/i`.
- **`help_list_workflows` duplicated sentence** — resolved in the
  Critic repair (it was a README.md duplication, §f; `documentation.rb`
  is clean), no open item remains.
- **`test_task_smoke_constructs_job_without_executing`** appeared as a
  new baseline F at round-12 start (unverified hypothesis: environment
  drift in the smoke child); out of round scope, carried as
  baseline-identical.

## l. Ratification items (consolidated)

1. **The outcome-C deviation**: `run_probe` with a `source` input
   (create-and-run: save, syntax-check, execute, independent outcomes,
   never revert) as the accepted replacement for auto-run-on-write/edit;
   generic write/edit/list/move/rename/delete never execute a probe.
2. **Root spelling** `share/probes/` (plural) — new root spelling, no
   checkout precedent; pinned by implementation and tests.
3. **Single-probe scope** for `run_probe` — no directory or suite scope
   (unlike `run_test`).
4. **Timeout envelope** — default 120 s, bounds 1..3600 (same envelope
   as `run_test`).
5. **Entity third-state tools** — export `define_entity` /
   `define_entity_property` (uncomment their `export_exec`) or retire
   them fully next round; today they are callable but invisible to
   agents.

## m. Commit status

Nothing committed anywhere, by standing instruction. All work is
uncommitted working-tree state in `/bulk/mvazque2/git/AgentSuite/ScoutCoder`:
the probe kind and runner, the pin test and 11 new tests, the README
sweep, the four comment-only task-file updates, this research note, and
the round-12 evidence under `tmp/path_kinds/round12/` and `tmp/notes/`.
The engine checkout `/bulk/mvazque2/git/scout-ai` was only read. A
Cortex artifact summary exists (`cortex artifacts: round12/`).
