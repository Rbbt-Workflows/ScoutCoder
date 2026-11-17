# ScoutCoder developer documentation

Internals, contracts and design decisions of the ScoutCoder workflow.
Agent-facing usage lives in `../../README.md` and
[doc/user/](../user/README.md); this tree owns the developer view.

ScoutCoder is an AI-assisted Scout workflow for retrieving framework
documentation and developing Scout workflows over a local repository
checkout: it explores installed workflows and authors, inspects, and tests
workflow tasks, helpers, and entity definitions. The workflow being
developed or explored is the one defined by the `workflow.rb` file in the
current process directory (`PWD`), treated as the repository root.

## Contents

- [Layout and documentation sources](Layout.md) — repository layout, the
  `share/` draft-loading convention, documentation-repo resolution order.
- [LiveWorkflow and WorkflowReload](LiveWorkflow.md) — the live-draft load
  order contract, reload semantics, and the workflow-level reload build.
- [Property dispatch](PropertyDispatch.md) — the four property types,
  receiver shapes, return shapes, caching, and the generator/inference
  behavior of the entity path kinds.
- [Path kinds internals](PathKindsInternals.md) — engine registration of the
  six kinds, capability matrix, tier-mapping ratification status, the
  no-autorun contract, the promotion reload hook, trust/sandbox registration
  shapes.
- [Testing internals](Testing.md) — how `run_test` and `run_probe` runners
  work: fresh-process anchors, exit-code mapping, process discipline, seams.

## Corrections carried into this tree

These were stale or unverifiable in the former single-file README and are
corrected here (audit: `doc_redesign/ScoutCoder.dossier.md`):

1. `lib/ScoutCoder/entity/` does **not** exist in the checkout (the README
   said it "exists but is empty"); `workflow.rb` requires no entity or
   entity-property files.
2. `share/` contains only `probes/` and `tasks/` (both empty);
   `share/helpers/`, `share/entities/`, `share/entity_properties/` and
   `share/test/` are absent, not "empty" — LiveWorkflow tolerates missing
   share subdirectories.
3. The entity-case decision artifact lives at
   `var/cortex/artifacts/reports/entity-case-convention-decision.md`, not
   bare `reports/…`.
4. `property.rb` line citations were re-verified against the installed
   scout-gear 10.13.1 gem and are pinned to that version in
   [PropertyDispatch.md](PropertyDispatch.md).
5. `doc/` now exists (this tree); the README is no longer the sole
   documentation file.
6. The registered task count is **18** (verified:
   `ruby -Ilib -e 'require "./workflow"; puts ScoutCoder.all_tasks.size'`
   → 18; the README `# Tasks` section carries exactly 18 entries), and
   all 18 are agent-exposed (`LLM.workflow_tools(ScoutCoder)` surfaces
   every task; campaign exposure table
   `doc_redesign/consolidation/task_exposure.tsv`).
