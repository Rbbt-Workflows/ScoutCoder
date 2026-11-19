---
name: scoutcoder-path-kinds-lifecycle
description: Drive the full ScoutCoder path-kind lifecycle for one artifact - author a draft, validate it, run its paired test, smoke it, then promote and wire it. Use when creating or changing a workflow task, entity, property, Python task, test file or probe, or when choosing between path_validate, path_smoke, path_run, run_task or planning a promotion. Entity/property/Python-task formats, naming rules and identifier TSVs belong to the scoutcoder-entity-authoring skill instead. Triggers path_write, path_validate, path_smoke, path_run, run_task, promote, paired test, draft, test_file kind, probe kind, wire into workflow.rb, reload_workflow.
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
   run it with `path_run` (`kind: "test_file"`); assertions execute in a
   fresh process. Canonical virtual
   path for a property test: `kind=test_file path=entity_property/Gene/onset`
   (dotted `Gene.onset` spellings are the tmp-side FILE name, not the path).
4. **Smoke** — `path_smoke` (SOURCE kinds only: task, entity,
   entity_property, python_task) to confirm the draft initializes/registers
   under the real workflow load. `test_file` has no smoke; `path_run`
   (`kind: "test_file"`) is its executing check.
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
| Behavior assertion holds | `path_run` (`kind: "test_file"`) on the paired test | Fresh process, UNSANDBOXED by design; trusted code only |
| Ad-hoc snippet against the loaded workflow | `path_run` (`kind: "probe"`) | Fresh unsandboxed child, caller's authority |
| Invoke the workflow task itself | `run_task` | Ordinary Scout job execution; no assertions |

Behavior claims need `path_run` (`kind: "test_file"`) or `run_task`,
never smoke alone.

## Promotion doctrine

- Promotion moves one resource; it does NOT wire `workflow.rb`, load the
  promoted file, relocate the paired test, or coordinate multi-file
  changes. Related resources promote separately.
- Every promotion result reports the destination and a
  `promotion_status`: `succeeded` (immediate reload ran), `reload_failed`
  (move complete; only the reload failed — the result carries the original
  diagnostic; fix the cause and reload, do not re-promote), or `deferred`.
- Related promotions in sequence (the canonical case: an entity, then its
  properties) should DEFER the per-promotion reload: pass the caller
  argument `defer_reload: true` to each promote, then wire once and reload
  once —
  1. promote the entity with `defer_reload: true` (result:
     `promotion_status: "deferred"`; `deferred_reload` names the root to
     reload later);
  2. promote each property with `defer_reload: true`;
  3. wire `workflow.rb`: entity require BEFORE the LiveWorkflow share
     load, property require AFTER;
  4. fire exactly ONE explicit `reload_workflow` with the checkout `root`
     (or `run_task` with `clean: true` on the reload job);
  5. verify from a fresh process that the wired artifact loads.

- Permanent source/wiring changes are explicit Workspace edits; inspect
  before editing, smallest scoped change, preserve conventions.
- After promotion + wiring, verify the workflow from a fresh process — a
  successful promote is not proof of correct behavior.
- `reload_workflow` is the in-process way to see drafts; a single promote
  fires it automatically through the `promotion_post_move` hook unless
  deferred as above.

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
- Treating engine authorization as a sandbox; `path_run` runs trusted
  code unsandboxed (both kinds).

## Going deeper

- Virtual paths, roots, validate lists, trust boundaries, lifecycle:
  [doc/user/PathKinds.md](../../doc/user/PathKinds.md).
- Runner choice, exit codes, running a task directly, documentation during
  promotion: [doc/user/Testing.md](../../doc/user/Testing.md).
- Tool-by-tool selection table:
  [doc/user/ToolSelection.md](../../doc/user/ToolSelection.md).
