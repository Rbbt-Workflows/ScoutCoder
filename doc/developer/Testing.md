# Testing internals

How the `run_test` and `run_probe` runners work: fresh-process anchoring,
dispatch, exit-code mapping and process discipline. The operational
workflow (choosing a runner, authoring test files, lifecycle) lives in
[doc/user/Testing.md](../user/Testing.md).

## `run_test` custom operation mechanics

Inputs: `kind` (always `test_file`), `path` (the virtual test-file path; `.`
selects the whole suite), `scope` (`file`, `directory` or `suite`; default
`file`), optional `location` (`tmp`, the default, `project`, or `python`)
and optional `timeout_seconds` (per-file, default 120).

**Dispatch by extension.** A `.rb` test file runs in its own fresh Ruby
process that loads the `workflow.rb` of the project checkout that OWNS the
test file — so LiveWorkflow live-loads that checkout's `share/` drafts —
and then loads the test file. A `.py` test file (the `python_task` tier at
the `python` location) runs in its own fresh Python process:
`python3 -m unittest <module>` from the checkout owning the test tree, with
`PYTHONPATH` seeded from `ScoutPython.paths` (so `import scout` resolves)
and `PYTHONDONTWRITEBYTECODE=1` (no `__pycache__` is ever created in the
test tree). The standard-library runner serves; scout-rig 0.2.6 ships no
Python test runner of its own. The same process discipline applies as for
Ruby: process group, TERM, ten seconds of grace, then KILL; per-file
timeout 1..3600 seconds. Python exit-code semantics map to the shared
classes: 0 → `clean_pass`, 1 → `assertion_failure` (the test RAN and
failed — `passed` is false, `ran` is true), 5 (`NO TESTS RAN`) or a
zero-test discovery → `load_error` (neither passed nor ran).

**Anchor chain.** The owning checkout is resolved by climbing from the test
file's location to the first directory containing `workflow.rb`; an
explicit `PATH_KIND_PROJECT_ROOT` constant (the regression-suite seam)
overrides the anchor, and the final fallback is the ScoutCoder checkout;
the full fallback chain is documented in
`research/path-kind-contract-fixes.md`. The per-file result reports
`workflow_loaded`, the absolute path of the `workflow.rb` the child loaded
(Ruby) or the owning checkout (Python).

**Scopes.** `scope: file` runs exactly one file; `scope: directory` runs
every test file under a path prefix; `scope: suite` (conventionally with
`path: "."`) discovers and runs every test file in both Ruby locations plus
the `python` location. Empty discovery (no test files found) is an error,
not a clean zero. Per-file timeouts default to 120s (`file` and `directory`
scopes) or 300s (`suite` scope), overridable through `timeout_seconds`.
The result reports, per file, the exit status, a classification
(`clean_pass`, `assertion_failure`, `load_error`, `timeout`), the test and
assertion counts and the captured output, with `passed` and `ran` as
SEPARATE booleans (a failing test `ran` but did not `pass`; a load error or
timeout did neither), and the aggregate carries
`count`/`passed`/`failed`/`not_run` plus an overall `ok`. The
workflow-level `run_test` task wraps the same runner for programmatic use.

## `run_probe` custom operation mechanics

Inputs: `path` (the bare probe name, no `.rb` suffix, no `share/probes/`
prefix — single-probe scope only, no directory or suite scope), optional
`source` and optional `timeout_seconds` (integer 1..3600; default 120).

**Create-and-run semantics of `source`.** When `source` is given the call
does THREE things in one tool call: writes/overwrites the probe file at
`share/probes/<name>.rb`, syntax-checks the saved source with an AST-only
parse, and — only when the parse succeeds — executes it in the fresh child.
The result reports the three stages as INDEPENDENT outcomes: `saved`
(true/false plus the physical target), `syntax_ok` (with `syntax_error`
text when false) and the `execution` block. A syntax failure means
saved-but-not-executed; a runtime failure NEVER reverts or deletes the
saved source — the failure is reported (`exit_class=raised`, the exception
class and message, stderr, exit status) with the file still on disk, so a
probe can be fixed and rerun. With `path` only, the existing saved probe is
re-executed unchanged and the run reports the same execution fields plus
`executed`.

**Execution environment.** Each run spawns a fresh UNSANDBOXED Ruby child.
The child first preloads the owning checkout's `workflow.rb` (the same
anchor chain as `run_test`, including the `PATH_KIND_PROJECT_ROOT` seam),
then loads the probe file, so a probe can use Scout constants and naturally
exercises imports OUTSIDE the Workspace bwrap grants — that reach is the
motivating capability, not an accident. Process discipline: process-group
kill, TERM, ten seconds of grace, then KILL; per-probe timeout 1..3600
seconds (default 120). Failures are normalized into Scout exceptions or
structured envelopes — a non-Scout exception never escapes raw. The result
reports `workflow_loaded` (the checkout the child loaded), the runner
spelling, captured `stdout`/`stderr`, `exit_status`, `duration_seconds` and
an `exit_class` of `completed`, `raised` or `timeout`.

**Trust contract.** `run_probe` executes trusted Ruby with the caller's
authority, outside any OS sandbox, and the `probe` kind is meant for
ScoutCoder agents investigating the Scout framework itself — not for general
computation (use a workflow task for that) and not for user-supplied
untrusted code. Expose the kind (and the `run_probe` task) only to agents
that may already execute trusted Ruby in this checkout.

## Smoke mechanics (source kinds)

`path_smoke` never runs a Scout job or inference. It exists on the four
SOURCE kinds only (`task`, `entity`, `entity_property`, `python_task`) —
the round-9 contract is "the resource can be
initialized/constructed/registered", never "it executes": `task` loads the
real workflow in a fresh process and CONSTRUCTS the task's job with
placeholder values for its required inputs only, never executing it;
`entity` asserts the module is defined and registered in `Entity::MODULES`,
with no dispatch; `entity_property` asserts the property is registered on
its module and that its accessor resolves to an `UnboundMethod` — the
property body is never dispatched; `python_task` runs a fresh Ruby child
that loads the real workflow, registers the draft through
`PythonWorkflow.load_directory`, and CONSTRUCTS the task's job Step with
placeholder values for its required inputs only (Python requiredness:
explicit `required` flag, or no default and not explicitly optional) — the
task body is never executed, and the metadata run never imports the draft.
`test_file` has NO smoke (removed in round 10): the same evidence is
produced by `run_test`, which actually executes the tests in a fresh
process and reports `passed`, `ran`, the exit status and the exit
classification separately — so a FAILING test is visible as a failure, not
as a passing "it ran" smoke.
