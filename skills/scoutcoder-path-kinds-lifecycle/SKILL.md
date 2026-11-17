---
name: scoutcoder-path-kinds-lifecycle
description: Drive the full ScoutCoder path-kind lifecycle for one artifact - author a draft, validate it, run its paired test, smoke it, then promote and wire it. Use when creating or changing a workflow task, entity, property, Python task, test file or probe, or when choosing between path_validate, path_smoke, run_test, run_probe and run_task, or planning a promotion. Entity/property/Python-task formats, naming rules and identifier TSVs belong to the scoutcoder-entity-authoring skill instead. Triggers path_write, path_validate, path_smoke, path_promote, run_test, run_probe, run_task, promote, paired test, draft, test_file kind, probe kind, wire into workflow.rb, reload_workflow.
---

# Path-kind operational lifecycle: author, validate, test, probe, promote

## What this skill covers

HOW to run the loop for one artifact through ScoutCoder's six registered
path kinds: the operational order, runner choice, promotion doctrine and
wiring. WHAT to author for entities, properties and Python tasks (formats,
naming rules, identifier TSVs, production-vs-dev dispatch) is owned by the
sibling skill `scoutcoder-entity-authoring`; this skill drops that detail.
Virtual-path rules, per-kind roots and validate check lists are owned by
[doc/user/PathKinds.md](../../doc/user/PathKinds.md).

## The loop (one artifact)

1. **Author** — `path_write` the draft at its `tmp` location.
2. **Validate** — `path_validate` for shape/syntax. Static only: it does
   not run the target.
3. **Test** — `path_write` the paired test as a `test_file` resource, then
   `run_test` it; assertions execute in a fresh process.
4. **Smoke** — `path_smoke` (SOURCE kinds only: task, entity,
   entity_property, python_task) to confirm the draft initializes/registers
   under the real workflow load. `test_file` has no smoke; `run_test` is
   its executing check.
5. **Promote** — `path_promote` moves exactly ONE resource to the project
   side; promote the paired test SEPARATELY through the `test_file` kind.
6. **Wire** — edit `workflow.rb` with Workspace; only then is the promoted
   artifact live. Verify from a fresh process (`reload_workflow` or a new
   process) after wiring.

## Choosing the check (decision table)

| Claim you need to support | Tool | Boundary |
|---|---|---|
| File is syntactically the right shape | `path_validate` | Static; runs nothing |
| Task job constructs / entity registers / property accessor resolves | `path_smoke` | Source kinds only; no task execution, no property dispatch |
| Behavior assertion holds | `run_test` on the paired test | Fresh process, UNSANDBOXED by design; trusted code only |
| Ad-hoc snippet against the loaded workflow | `run_probe` (probe kind) | Fresh unsandboxed child, caller's authority |
| Invoke the workflow task itself | `run_task` | Ordinary Scout job execution; no assertions |

Behavior claims need `run_test` or `run_task`, never smoke alone.

## Promotion doctrine

- Promotion moves one resource; it does NOT wire `workflow.rb`, load the
  promoted file, relocate the paired test, or coordinate multi-file
  changes. Related resources promote separately.
- Permanent source/wiring changes are explicit Workspace edits; inspect
  before editing, smallest scoped change, preserve conventions.
- After promotion + wiring, verify the workflow from a fresh process — a
  successful promote is not proof of correct behavior.
- `reload_workflow` is the in-process way to see drafts; some reload paths
  fire automatically (e.g. promotions through the `promotion_post_move`
  hook).

## Fresh process is not fresh result

Test runners start a new process, but Scout's job/Step caches outlive it.
For a regression check that matters, use `run_task`'s `clean: true`, clean
the exact job/Step, or inspect reported replay status — otherwise you may
be reading a cached success.

## What the loop does NOT decide for you

Artifact formats, naming rules (entity CamelCase, property snake_case),
the extend-line ownership rule and identifier TSVs are
`scoutcoder-entity-authoring`'s territory — check that skill before
authoring; this skill only moves the artifact through the loop.

## Common mistakes

- Promoting and assuming the artifact is live (no `workflow.rb` wiring
  happened).
- Expecting the paired test to move with its source (it does not).
- Using `path_smoke` as evidence of behavior.
- Editing non-registered files (wiring, docs, data) with path tools — the
  kinds address ONLY their six roots; use Workspace for everything else.
- Treating engine authorization as a sandbox; `run_test`/`run_probe` run
  trusted code unsandboxed.

## Going deeper

- Virtual paths, roots, validate lists, trust boundaries, lifecycle:
  [doc/user/PathKinds.md](../../doc/user/PathKinds.md).
- Runner choice, exit codes, running a task directly, documentation during
  promotion: [doc/user/Testing.md](../../doc/user/Testing.md).
- Tool-by-tool selection table:
  [doc/user/ToolSelection.md](../../doc/user/ToolSelection.md).
