# Testing and execution

Choose the runner by what you are trying to establish:

- Use `path_validate` to check a virtual resource's static shape and syntax.
- Use `path_smoke` on `task`, `entity`, `entity_property`, or `python_task`
  to verify initialization/registration without executing domain behavior.
- Use `path_run` with `kind: "test_file"` for a test file managed by the
  `test_file` kind, including directory or suite scopes.
- Use `path_run` with `kind: "probe"` for an unsandboxed one-off
  Scout-framework investigation snippet managed by the `probe` kind.
- Use `run_task` to exercise a workflow task directly through the normal
  Scout job system. It is a behavior probe, not a substitute for an
  assertion-based test.
- Use `job_info` and `job_status` to inspect an existing job without
  re-running it.

## Authoring and running tests

Test code is ordinary trusted program code. The general test-file lifecycle
is:

1. Create or inspect the source resource and use `path_validate`.
2. Write the paired test through `path_write` on kind `test_file`. Virtual
   examples are `task/greet_user`, `entity/DemoWidget`,
   `entity_property/DemoWidget/tag_palette`, `integration/round_trip`, and
   `python_task/my_task` (at `location: python`). Do not include the
   physical `share/test/`, `test/<workflow>/` or `python/test/` roots, or a
   `.rb`/`.py` suffix, in the virtual path.
3. Run the test with `path_run` (`kind: "test_file"`) at
   `scope: "file"`. Widen to `directory` or `suite` only when a broader
   check is useful. A zero-file discovery is an error, not a passing
   empty suite.
4. For source kinds, separately use `path_smoke` when load/registration
   needs verification. A passing smoke check does not prove behavior.
5. If the source and test should be permanent, promote each resource
   separately with `path_promote`. The engine moves one resource per
   operation; it does not move its paired test for you.
6. After promoted source is wired into `workflow.rb`, re-run the test or
   relevant suite from a fresh process.

The paired-test tier conventions (`share/test/task/<name>.rb` on the tmp
side, `test/<workflow>/tasks/test_<file>.rb` for shipped task code under
`lib/<workflow>/tasks/`) remain the naming rule for a task's test; the
`test_file` kind and `path_run` (`kind: "test_file"`) are the authoring and
execution surface for both sides.

A test file for the generic runner uses the Test::Unit shape:

```ruby
require 'test/unit'

class MyTaskTest < Test::Unit::TestCase
  def test_example
    assert_equal 2, 1 + 1
  end
end
```

A Python test file (the `python_task` tier, written as
`python_task/<name>` at `location: python` and stored physically as
`python/test/test_<name>.py`) uses the unittest shape:

```python
import unittest

class TestMyTask(unittest.TestCase):
    def test_example(self):
        self.assertEqual(2, 1 + 1)
```

`path_run` (`kind: "test_file"`) dispatches on the file extension: `.rb`
files run as Ruby
Test::Unit (fresh Ruby process loading the owning checkout's
`workflow.rb`), `.py` files as Python unittest (`python3 -m unittest`,
`PYTHONPATH` from `ScoutPython.paths`, no `__pycache__`). Exit-code
semantics: Python 0 → `clean_pass`, 1 → `assertion_failure`, 5
(`NO TESTS RAN`) or zero discovered tests → `load_error`; `passed` and
`ran` stay separate booleans for both languages. `path_run` (`kind: "test_file"`) mechanics
(fresh per-file process, anchor contract, exit classification, `passed` vs
`ran`) are documented once in
[doc/developer/Testing.md](../developer/Testing.md) and the
[Path kinds guide](PathKinds.md) § `path_run`. Both specialized and general test runners start fresh
processes, but Scout job/Step results are persistent and are not
automatically cleared; see [Fresh process versus fresh
result](ToolSelection.md#fresh-process-versus-fresh-result).

The test-file path convention (a test mirrors its tested file's path under
the test tree) is ScoutCoder doctrine, with the pairing map in
[PathKinds.md](PathKinds.md#paired-test-convention); scout-rig's suite is
the worked example — scout-rig `doc/user/TestingAndPackaging.md` § "Test
suite layout mirrors `lib/`" (that document is scout-rig's own
build/test/packaging story, not a general conventions reference).

## Understand execution and sandbox boundaries

Path Engine authorization is not a process sandbox, and `path_run`
intentionally executes trusted test code unsandboxed; the canonical
statement is [Trust boundaries](PathKinds.md#trust-boundaries), with
engine-level semantics in scout-ai `doc/developer/Sandbox.md` § "1. Is
this tool sandboxed?" and `doc/developer/PathEngine.md` § "8. Callback
contract and trust boundary".

`run_task` executes a normal Scout workflow job. Use it to test task
behavior through Scout's standard execution path, not to try to perform
arbitrary file operations through a file-oriented tool. Do not assume
`run_task` is OS-sandboxed unless a separate runtime boundary explicitly
establishes that. `run_task` returns whether a result was replayed; pass
`clean: true` when the addressed job must be recomputed.

The distinction can avoid misleading sandbox-related failures: a test that
needs ordinary workflow loading or runtime behavior should be run by
`path_run` (`kind: "test_file"`) or a normal workflow job by `run_task`,
rather than being
coupled to Path Engine read/write operations. Timeouts and output capture
are operational controls, not process isolation. Only execute trusted code
and pass explicit inputs.

A test should assert the intended behavior, including error and edge cases
where relevant; syntax, registration, and mere process exit are not
sufficient evidence of correctness.

## Running a task directly

`run_task` takes `workflow`, `task`, JSON text in `inputs` (default `{}`),
and `clean` (default `false`). It executes synchronously and returns
status, output, job path, replay status, and captured error. Inspect inputs
and dependencies before execution when the task contract is not obvious:

```ruby
ScoutCoder.job(:task_inputs, nil,
  workflow: 'Workspace',
  task: 'read'
).run

ScoutCoder.job(:run_task,
  workflow: 'Workspace',
  task: 'read',
  inputs: '{"path":"README.md"}',
  clean: true
).run
```

(The example workflow is `Workspace`; the same call shape works for any
loadable workflow. It uses a maintained workflow on purpose — ComputerUse,
which older examples cited, is deprecated.)

Use `job_info` or `job_status` when you already know the workflow, task,
and inputs for an existing job and only need to inspect it.

**Where job outputs land.** `run_task` jobs persist under the checkout's
`var/jobs/<Workflow>/<task>/<id>/` (relative to the project root of the
workflow that ran the job); the result receipt returns the job path, its
short path, and the replay status. Inspect without re-running via
`job_info`/`job_status`, and pass `clean: true` when a recompute is
required instead of hunting for outputs by hand.

## Documentation during promotion

While a task lives under `share/tasks/`, its documentation is normally in
its `desc`. When promoted into `lib/<workflow>/tasks/`, follow the project's
convention: remove the draft-only `desc` and document the shipped task in
the README's `# Tasks` section with `document_task`. Do not assume this
documentation change happens automatically from file promotion.

The `ScoutCoder:` comment convention (see
[Documentation.md](Documentation.md)) closes its loop here: promoted
`ScoutCoder:` comments are the raw material for `document_task` entries and
for repo-documentation improvements. When a comment's fact is settled, move
it into the README entry or the relevant repo doc instead of letting
discoveries accumulate as comments.
