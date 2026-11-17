---
name: scoutcoder-entity-authoring
description: Author Scout workflow entities, entity properties and Python tasks as ScoutCoder path-kind drafts instead of hand-placed files. Use when a workflow needs a new entity module, a property (including generated types), a Python-backed task, or the identifier TSVs entities consume; covers naming rules, validate checks, list_entities, and how drafts register on workflow reload. Triggers path_write kind=entity, path_write kind=entity_property, python_task, entity module, entity property, generated property, identifier TSV, list_entities, CamelCase entity, snake_case property, extend Entity.
---

# Authoring entities, properties and Python tasks

## What this skill covers

WHAT to author: which kind to write through for each artifact, the naming
rules validate enforces, the extend-line ownership rule, the file formats
and identifier TSVs drafts consume, and production-vs-development dispatch.
HOW to run the author→validate→test→smoke→promote loop (runner choice,
promotion doctrine, wiring) is owned by the sibling skill
`scoutcoder-path-kinds-lifecycle`; this skill stops at the artifact itself.
File formats and generated shapes are owned by
[doc/user/AuthoringEntities.md](../../doc/user/AuthoringEntities.md) — do not
duplicate them here.

## Write through the kinds, not by hand

| You need | Kind and path | Where the draft lands |
|---|---|---|
| New entity module | `path_write kind=entity path=<Name>` | `share/entities/<Name>.rb` |
| Property on an entity | `path_write kind=entity_property path=<Entity>/<prop>` | `share/entity_properties/<Entity>/<prop>.rb` |
| Python-backed task | `path_write kind=python_task path=<name>` | the kind's registered root |
| Test for any of the above | `path_write kind=test_file path=...` | paired-test location |

Hand-placing these files under `share/` duplicates what the kinds do
(extension-free paths, root validation, reload registration) and skips
`path_validate`.

## Naming rules validate enforces

- Entity TYPE names CamelCase `[A-Z][A-Za-z0-9]*` (all-caps acronyms like
  `TF` allowed); property names snake_case `[a-z][a-z0-9_]*`.
- Legacy snake_case entity names still validate with a warning; two cases
  are HARD errors — constant collisions with a coexisting CamelCase draft,
  and two snake names whose camelized constants collide.
- The file name's constant must match the module declaration
  (`DemoWidget.rb` → `module DemoWidget`).

## Ownership rules that bite

- The **entity** file owns the `extend Entity`/`extend EntityWorkflow`
  line; an `entity_property` draft must NOT carry one.
- The property draft declares `property :name => :type do ... end` (or the
  typeless `property :plain do`, dispatching as `:both`).
- Entity drafts load before property drafts on every workflow reload; a
  property needs its entity to exist first.

## Confirm registration, not just file existence

A draft is registered when `reload_workflow` (or a fresh process) plus
`list_entities` shows the entity in the loaded workflow. Validation and
smoke are checks inside that loop; which check proves which claim, how to
run them, and the full validate→smoke→promote order are the sibling
skill's territory (`scoutcoder-path-kinds-lifecycle`).

Do not treat file existence or successful validation as proof the entity
works; dispatch behavior is exercised through `run_task`/`run_test`.

## Identifier TSVs and Python tasks (what to author)

- Python tasks author through the `python_task` kind: function definitions
  plus an explicit `scout.task(...)` registration with its own top-level
  `import scout`; the module docstring convention and the exact file shape
  are in [doc/user/AuthoringEntities.md](../../doc/user/AuthoringEntities.md).
- Entities consuming identifier TSVs: one non-empty TSV per entity at
  `share/entity/<entity>.identifiers.tsv` with a `TSV.parse_header`-accepted
  header naming the identifier formats; registration is the entity
  definition's `add_identifiers` call, whose path is file-relative so it
  does not depend on the process working directory. Conventions reference:
  scout-gear `doc/user/WorkingWithEntities.md` § "Format and identifier
  translation"; exact shapes on the AuthoringEntities page.

## Production versus development dispatch (which surface sees a fresh draft)

A production dispatch surface (such as Semantics' `entity_property` task)
dispatches what its own process loaded and does NOT reload `share/` drafts
defined after it started — a fresh draft is invisible to it until that
process reloads. Development verification of a fresh draft therefore goes
through `run_probe` (fresh child, preloads the owning checkout's
`workflow.rb`, dispatches exactly as a newly loaded process would). The
full dispatch matrix of the four property types:
[doc/developer/PropertyDispatch.md](../../doc/developer/PropertyDispatch.md).

## Common mistakes

- Hand-editing `lib/<workflow>/entity/` paths — that tree does not exist in
  this checkout; drafts live under `share/`.
- Putting the extend line in a property draft.
- Authoring a property before its entity draft loads.
- Expecting a production dispatch surface to see a draft authored after it
  started.

## Going deeper

- Formats, generated shapes, `list_entities` output:
  [doc/user/AuthoringEntities.md](../../doc/user/AuthoringEntities.md).
- The operational loop (validate, smoke, promote, wiring): the sibling
  skill `scoutcoder-path-kinds-lifecycle` and
  [doc/user/PathKinds.md](../../doc/user/PathKinds.md).
