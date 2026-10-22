# Path kinds round 11 — the `python_task` kind and the Python test tier

Round 11 of the incremental path-kinds implementation (rounds 6–10 built
the four Ruby kinds; round 10 hardened `test_file`/`run_test`). This
round added a fifth kind, `python_task`, translating the legacy
Python-task support (`define_python_task`, `python_task_support.rb`) into
the path-kind architecture, then made Python tests addressable as
`test_file` resources at a third location and executable through
`run_test`. This note is the durable record.

**Nothing is committed anywhere.** All work is uncommitted working-tree
state in `/bulk/mvazque2/git/AgentSuite/ScoutCoder`. The engine repo
`~/git/scout-ai` was read throughout and never patched.

## a. Summary

1. **Engine drift resolved as a commit.** The bout-1 baseline recorded
   path.rb md5 `0d55806e…` on HEAD `ee9c90c` **with an uncommitted
   working-tree diff**. Mid-round that diff became commit `3719551`
   "Fixed path engine contract" (tree clean, md5 `c1d9e351…`). All
   round-11 implementation, adaptation and verification ran against
   `c1d9e351…`; the engine was never modified by ScoutCoder.
2. **`outside_grants` failures were ScoutCoder-side, not engine
   defects.** Contract after 68add84/3719551: *a path-kind operation
   authorizes the resolved target against the KIND ROOT pinned for that
   location — not the process CWD — and engine-generic `path_list`
   resolves and authorizes the root it enumerates.* Four
   `test_path_kinds.rb` tests asserted pre-fix leniency; all four were
   adapted (see §g).
3. **New kind `python_task`** — generic lifecycle + validate/smoke/
   promote, drafts `share/python_tasks/`, promoted `python/tasks/`,
   extension `.py`, registered in `PATH_KINDS` beside the four Ruby
   kinds.
4. **Third `test_file` location `python`** — root `Scout.python.test`,
   hosting exactly the `python_task` tier as `python_task/<name>` ⇔
   `test_<name>.py` (the legacy scout-rig spelling), foreign tiers
   rejected at that location.
5. **`run_test` dispatches by extension** — `.rb` unchanged; `.py` runs
   `python3 -m unittest <module>` with the same process discipline and
   the same honest `passed`/`ran` split.

## b. Conventions held; new ones established this round

Held from rounds 6–10 (no change): canonical virtual-path validation
before any filesystem call; one reversible hierarchy-preserving mapping
authority (`PathKindTestFiles`); prefix-honoring list; registration-time
root resolution through the current workflow; `.find(:current)`, never
bare `.find`; smoke = initialization-only; promotion = one resource,
declarative destination, engine moves it, no post-move hooks, no-clobber
default.

New this round:

- **Engine root-authorization contract (3719551)**: engine-generic
  operations (`path_list` and friends) resolve and authorize against the
  kind's pinned root for the addressed location. Test harnesses that
  point a kind copy's roots inside a sandbox must authorize through the
  copy, and must not rely on the process CWD covering the target.
- **Extension is a mapping-authority concern, not a kind-level constant
  for multi-location kinds.** `test_file` keeps `'extension' => 'rb'`
  as the engine default; the resolve hook owns the real extension,
  branching on tier (`python_task` → `.py`). Virtual spellings stay
  extension-free, which also sidesteps the engine's
  `set_extension`-always-appends quirk (a dotted spelling fed to resolve
  yields `a.py.py`).
- **A tier may be bound to exactly one location.** `python_task` lives
  only at `python`; its tier directory is virtual-only there. This is a
  mapping-authority decision recorded in `test_file.rb`, mirroring the
  project side's fixed `task → tasks` rename.

## c. Working recipe

Author, check, test, promote a Python task and its test:

```bash
# 1. draft (share/python_tasks/greet_user.py)
#    path_write kind=python_task path=greet_user location=tmp
# 2. static checks (name, non-empty, ast.parse, scout.task scan)
#    path_validate kind=python_task path=greet_user
# 3. initialization-only check (loads workflow, registers via
#    load_directory, constructs the job with required-input placeholders;
#    never executes the body)
#    path_smoke kind=python_task path=greet_user
# 4. the paired test, as a test_file resource at the python location
#    path_write kind=test_file path=python_task/greet_user location=python
#    # -> python/test/test_greet_user.py
#    run_test kind=test_file path=python_task/greet_user location=python
# 5. promote (declarative; engine moves; no-clobber unless overwrite)
#    path_promote kind=python_task path=greet_user
# 6. wiring: NONE in workflow.rb — the workflow's own python/tasks
#    discovery picks it up on the next load in a fresh process.
```

## d. Findings

- **Python availability.** `python3` 3.13.3; `import scout` resolves
  once `PYTHONPATH` includes the gem's `python/` dir;
  `ScoutPython.paths` already seeds exactly that
  (`paths.rb: add_paths(Scout.python.find_all)`). `--scout-metadata`
  metadata inspection verified end-to-end.
- **Dead hardcode.** `python_task_support.rb:109` hardcodes
  `~/git/scout-rig`, which does not exist; root cause of 2 baseline
  failures (out of scope, left untouched). New code derives paths from
  `ScoutPython.paths` / `Scout.python.find_all` only.
- **Registration mechanics** (baseline probes `registration/d1`, `d2`):
  gem `scout/workflow/python.rb` `glob_names('*.py')` over
  `python/tasks/`; out-of-tree drafts load via
  `PythonWorkflow.load_directory(Path.setup(dir), name)` or
  `python_task(task_sym, file:, metadata:)`. Gotchas: `load_directory`
  requires a Path.setup'd string; the task is a Proc, schema comes from
  workflow declarations; the python workflow is usable from child
  processes only; no job-placement assumptions.
- **No gem test runner.** scout-rig 0.2.6 `python/` ships only the
  `scout` package; `ScoutPython` exposes task/metadata runners. The
  standard library serves: `python3 -m unittest <module>`.
  `unittest discover` was rejected: with `-p` patterns containing quotes
  (spaces in tmp dirs) it fails (`b1b`, `b1c` probes); plain module
  invocation has no such failure mode and is the only invocation whose
  exit codes are documented (0/1/5).
- **Extension resolution** (§b): branch in the resolve hook; keep the
  kind's `extension` as the engine default only.
- **Single-location tier** (§b): `python_task` at `python` only; the
  tier spelling is the legacy `test_<name>.py` with no physical tier
  directory.

## e. Evidence index

Claim map for the README statements: `tmp/notes/round11-claim-map.md`
(38 statements, each mapped to a `lib/` line, a green test, or a probe
output; zero unmappable).

| Claim | Evidence |
|---|---|
| Engine pin per bout | `kind/a0-engine-pin-before.txt`, `kind/z-engine-pin-after.txt`, `pytest/a0-engine-pin-before.txt`, `pytest/z-engine-pin-after.txt` |
| outside_grants diagnosis + adaptation | `kind/a-outside-grants-diagnosis.txt`; adapted tests in `test/ScoutCoder/test_path_kinds.rb` |
| python_task registration/idempotence/task-level narrowness | registration+idempotence: `kind/b1-registration.txt`, `kind/b1-registration-rerun.txt` + `test_python_task_kind_definition_surface`, `test_python_task_registration_idempotent`; task-level narrowness: `kind/b1c-task-level-narrowness.txt` (whole-workflow incorporation registers the five kinds, task-level incorporation leaves the registry empty) |
| python_task CRUD + underscore/nested names + round-trip | `kind/b2-generic-ops.txt`, `kind/b2-crud-probe.txt`, `kind/b2b-crud-rerun.txt` + `test_python_task_generic_crud_round_trip` |
| validate matrix (bad name/empty/syntax/no scout.task/happy; no `__pycache__`) | `kind/b3-validate-matrix.txt`, `kind/b3-validate-probe.txt` + `test_python_task_validate_matrix` |
| smoke matrix (stage=construct, executed=false, canary never appears, failures staged) | `kind/b4-smoke-matrix.txt` + `test_python_task_smoke_constructs_job_without_executing`, `test_python_task_smoke_failures_raise_with_stage` |
| promote matrix (success, no-clobber, overwrite, source intact) + containment (traversal/absolute/symlink, canary byte-identical) | `kind/b5-promote-matrix.txt` + `test_python_task_promote_matrix`, `test_python_task_containment_rejects_outside_targets` |
| Runner decision + rejected `discover -p` | `pytest/b0-design-decisions.txt`, `b1-runner-probe.txt`, `b1b-discovery-variants.txt`, `b1c-quoted-discovery.txt` |
| Extension behavior | `pytest/b2-extensions.txt` (`b2-extension-probe.rb`) |
| run_test file/dir/suite for `.py`; pass/fail distinguishable; Ruby unchanged; no `__pycache__` | `pytest/b3-run-test-probe.txt` (`b3-run-test-probe.rb`); tests `test_python_test_file_scope_pass_and_fail_distinguishable`, `test_python_test_directory_scope_runs_every_file`, `test_python_test_suite_scope_includes_python_location`, `test_python_test_syntax_error_is_load_error_not_silent` |
| Python-tier mapping round-trip, prefix list across three locations, containment negatives with byte-identical canary | `pytest/b4-map-list-containment.txt` (`b4-map-list-containment.rb`); tests `test_python_test_other_tiers_rejected_at_python_location`, `test_python_test_containment_denies_traversal_and_absolute` |
| Five-kind lock + python location in the test tree | `test_registered_kinds_match_readme_documented_set`; suite-scope empty-root seam at `test_path_kinds.rb:1187` |

## f. Reproduction commands

From the checkout root; every command a fresh process:

```bash
BWRAP_PATH=false ruby -Itest test/ScoutCoder/test_path_kinds.rb            # 43/630
BWRAP_PATH=false ruby -Itest test/ScoutCoder/test_path_kinds_roundtrip.rb  # 11/18

# full-suite enumeration (captures the 8 known F/E):
for f in $(find test -name 'test_*.rb' | sort); do
  echo "=== $f"; BWRAP_PATH=false ruby -Itest "$f" 2>&1 | grep -E "Failure:|Error:|tests,"
done

# self-recording probes (each writes its own .txt beside it):
BWRAP_PATH=false ruby tmp/path_kinds/round11/kind/*.rb
BWRAP_PATH=false ruby tmp/path_kinds/round11/pytest/b2-extension-probe.rb
BWRAP_PATH=false ruby tmp/path_kinds/round11/pytest/b3-run-test-probe.rb
BWRAP_PATH=false ruby tmp/path_kinds/round11/pytest/b4-map-list-containment.rb

# engine pin:
md5sum ~/git/scout-ai/lib/scout/llm/agent/path.rb   # c1d9e3516c79174eb7a590f8408ee4ef
git -C ~/git/scout-ai log --oneline -1              # 3719551
```

## g. Known-failure disposition

| Failure (baseline name) | Disposition |
|---|---|
| 8 name-identical round-10 F/E (HelperTools 2, PythonTaskTools 2 via the dead `~/git/scout-rig` hardcode, TaskTestTools 1, TestWorkflowTools 2, TestLiveWorkflow 1) | KEPT, name-identical; out of round scope; the 2 Python ones are the documented dead-hardcode fallout |
| `test_engine_authorized_set_excludes_paired_test_destination` (outside_grants) | FIXED BY ADAPTATION: sandbox `project` root was a never-granted `python/lib/…` path; now pinned to the real destination. `kind/a-outside-grants-diagnosis.txt` |
| `test_run_test_suite_scope_discovers_both_sides_and_empty_is_error` (outside_grants) | FIXED BY ADAPTATION: empty-suite arm now registers an empty-rooted kind copy instead of chdir'ing into a foreign tmpdir |
| `test_test_file_list_honors_prefixes` (outside_grants) | FIXED BY ADAPTATION: list now goes through the sandbox kind copy's pinned roots |
| `test_test_file_list_round_trips_virtual_paths` (outside_grants) | FIXED BY ADAPTATION: same as above |

## h. Engine md5 pins across the round

| Point | md5 | HEAD | tree |
|---|---|---|---|
| Bout-1 baseline | `0d55806e…` (uncommitted diff present) | `ee9c90c` | dirty |
| Bout-1 mid (diff committed upstream) | `c1d9e351…` | `3719551` | clean |
| Bout-2 start / end | `c1d9e351…` | `3719551` | clean |
| Bout-3 (this bout) start / end | `c1d9e351…` | `3719551` | clean |

## i. Open items for the user

- **Draft-root spelling ratification.** `share/python_tasks/` is a new
  root spelling with no precedent in the checkout (the Ruby kinds use
  `share/tasks|entities|entity_properties`). The implementation and the
  tests pin it; ratification is a user decision.
- **Legacy task removal decision.** `define_python_task` and
  `author_python_task_test` are marked SUPERSEDED in the README, remain
  functional, and their tests still run. Removal is the user's decision;
  removing them also removes the 2 dead-hardcode baseline failures.
- **List/resolve extension asymmetry** (engine property, recorded not
  worked around): engine `path_list` returns entries WITH their
  extension; feeding such a dotted spelling back to resolve double-appends
  (`a.py.py`) because `set_extension` always appends. Recorded in
  `kind/b2d-list-extension-note.txt` (probe `b2d-list-extension.rb`);
  user-facing docs deliberately omit it.
- **`test_file` location naming.** The location is spelled `python`
  while the Ruby ones are `tmp`/`project`; a future tier at a new root
  would extend the same pattern. No action needed; flagged for taste.
