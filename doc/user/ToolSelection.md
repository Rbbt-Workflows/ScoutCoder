# Tool selection and validation discipline

Use the tool whose responsibility matches the work. ScoutCoder provides
Scout-aware discovery and authoring; the Path Engine provides authorized
operations on registered virtual resources; Workspace is for general
repository edits; task and test runners execute code through the ordinary
workflow/process environment.

| Need | Preferred tool | Boundary |
|---|---|---|
| Understand existing workflow behavior | `help_workflow`, `list_tasks`, `task_inputs`, `task_dependencies`, `task_code`, `list_entities` | Inspection; no behavior should be inferred from a task name alone |
| Create a workflow task draft | `path_write` on the `task` kind | Writes under `share/tasks/` at the kind root, with no extension to remember; a workflow reload registers the draft, and the trusted draft may execute while loading |
| Manage a registered virtual source/test file | `path_kinds`, then `path_read`, `path_write`, `path_edit`, `path_list`, `path_validate`, `path_smoke`, `path_promote` as supported by the kind | Path authorization covers the addressed resource and configured roots |
| Run a test file | `path_run` with `kind: "test_file"` | Execution occurs in a fresh process, but `path_run` is deliberately unsandboxed |
| Run a probe snippet | `path_run` with `kind: "probe"` | Fresh UNSANDBOXED child running trusted code with the caller's authority; see [path_run](PathKinds.md#path_run-one-operation-two-runnable-kinds) |
| Exercise a workflow task directly | `run_task` | Uses ordinary Scout job execution; check cache replay and clean the addressed job when needed |
| Edit existing source, wiring, tests, or docs | Workspace | The path tools address ONLY the six registered kinds; for any other file — wiring, docs, data, config — use Workspace. Inspect the exact diff and retest; do not assume Workspace and workflow tools share an execution sandbox |

## Validation is layered

- `path_validate` is a static shape/syntax check. It does not run the target.
- `path_smoke` is available on source kinds only. It proves that a task job
  can be constructed with placeholders for required inputs, that an entity
  loads/registers, or that an entity-property accessor resolves. It does not
  execute a task or dispatch a property.
- `path_run` with `kind: "test_file"` executes assertions in an existing
  test file. Prefer a behavior-focused test over a smoke check when a
  behavior claim is being made.
- `run_task` is for invoking a workflow task itself, often as an interactive
  behavior probe. It does not provide assertions or act as a test suite
  runner.

## Execution is not the same as file authorization

Path Engine authorization is not a process sandbox, and `path_run`
intentionally executes trusted test code unsandboxed; the canonical
statement is [Trust boundaries](PathKinds.md#trust-boundaries), with
engine-level semantics in scout-ai `doc/developer/Sandbox.md` § "1. Is this
tool sandboxed?" and `doc/developer/PathEngine.md` § "8. Callback contract
and trust boundary".

Using `run_task` or `path_run` can avoid the wrong failure mode when a test
is being attempted through file-oriented Path Engine operations: execute
behavior through the workflow/test runner rather than pretending that a
file operation is an execution environment. This is a choice of the proper
tool boundary, **not a way to bypass security controls**. Only run trusted
code, pass explicit inputs, and test Path Engine authorization separately.

On the removed legacy `path_test` operation, see
[PathKindsInternals.md](../developer/PathKindsInternals.md) § "Canonical note on the removed legacy `path_test`";
do not depend on it in new work.

## Fresh process versus fresh result

Test runners start a new process, but Scout's persistent job and Step caches
outlive it. For a meaningful regression check, establish whether the
relevant job was recomputed: use `run_task`'s `clean: true` when
appropriate, clean a test's exact job/Step if its result needs refreshing,
and inspect the reported replay status. See scout-gear
`doc/user/CachingData.md` § "Where persistence lives (ecosystem split)" for
where job/Step results actually persist.

## Change and promotion doctrine

Inspect before editing. Make the smallest scoped change and preserve the
project's conventions. After writing source, read the file back, validate
it, run an appropriate load/registration check, and exercise the relevant
behavior. Do not treat file existence or successful registration as proof
of correct behavior.

Path-kind promotion moves exactly one resource. It does not wire a
task/entity/property into `workflow.rb`, load a promoted file, relocate a
paired test, or coordinate a multi-file change. Promote related resources
separately and make permanent source/wiring changes explicitly with
Workspace. Verify the resulting workflow from a fresh process.

Do not commit, push, or merge unless explicitly asked. Report the actual
checks performed and keep unresolved failures or unverified assumptions
visible.
