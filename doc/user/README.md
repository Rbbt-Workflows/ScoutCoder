# ScoutCoder user documentation

ScoutCoder provides tools to explore, execute, develop and validate
functionality within Scout workflows. Developer internals, layout and engine
registration live in [doc/developer/](../developer/README.md); the task
reference is in the repository [README.md](../../README.md).

## Exploring and extending workflows

ScoutCoder operates from the project checkout that owns the workflow.
Existing functionality can be investigated and executed without creating
new capabilities.

- **Probes**: exploratory computations and inspection of tasks, entities,
  resources and results. A probe can be the complete deliverable.
- **Tasks**: reusable computational operations with explicit inputs and outputs.
- **Entities and entity properties**: reusable access to domain-object
  information and computations.
- **Tests**: executable specifications of expected behaviour.

A probe is managed through the `probe` path kind and executed through
`path_run`. Launching Ruby or Scout through Workspace Bash is not equivalent:
the subprocess may have different filesystem visibility, workflow resolution
and loaded state. Missing dependencies there do not necessarily indicate a
problem with native workflow execution.

## Computational artifacts

Scout TSV is a keyed table format: the first column is the key and the
remaining columns are fields. Its column-name line starts with `#`,
optionally preceded by `#:` metadata describing type, namespace, cast and
other options. For example (columns separated by actual tabs):

```tsv
#: :type=:single :cast=:to_f :namespace=Hsa/feb2014
#Transcription Factor (Associated Gene Name)	Score
ATF1	2.4
EGR2	-1.8
```

Use this format for TSV outputs intended for Scout, including Python tasks
and probe artifacts. A `:list` has one scalar per value field; `:double`
has arrays of values per field, separated by `|` on disk by default.
Repeated keys can merge or overwrite records. Prefer native TSV
serialization in Ruby; ordinary dataframe exports must adapt the header,
key and value shape. See scout-gear `doc/user/ProcessingTabularData.md`
for the format and programming interfaces.

## Working with other agents

A delegation can specify a required computation without prescribing its
implementation. Technical discovery is part of ScoutCoder's responsibilities.
Return accessible result artifacts with provenance and relevant limitations.

Promotion changes workflow source but does not automatically update already
loaded processes. Force a reload and verify availability from the intended
consumer's execution context.

## Contents

- [Tool selection and validation discipline](ToolSelection.md) — choosing
  tools, layered checks, fresh process vs fresh result, change and promotion.
- [Authoring entities and Python tasks](AuthoringEntities.md) — entity,
  property and Python task formats, identifier TSVs, `list_entities`,
  production vs development dispatch.
- [Path kinds operational guide](PathKinds.md) — virtual paths, validation,
  smoke checks, `path_run` (tests and probes), promotion, wiring and
  [forcing a reload for the intended consumer](PathKinds.md#force-the-reload-and-verify-consumer-access).
- [Testing and execution](Testing.md) — runners, tests, exit codes, direct
  task execution and documentation during promotion.
- [Documentation lookup and the ScoutCoder: convention](Documentation.md) —
  the `help_*` discovery tools and documentation-improvement comments.
