# ScoutCoder user documentation

Agent-facing usage of the ScoutCoder workflow: how to choose tools, author
and validate drafts, run tests, promote, and look up framework
documentation. Developer internals, layout and engine registration live in
[doc/developer/](../developer/README.md); the task reference entries are in
the repository `README.md` (`# Tasks` section).

## Contents

- [Tool selection and validation discipline](ToolSelection.md) — which tool
  for which need, the layered checks, fresh process vs fresh result, change
  and promotion doctrine.
- [Authoring entities and Python tasks](AuthoringEntities.md) — entity,
  property and Python task file formats, identifier TSVs, `list_entities`,
  production vs development dispatch.
- [Path kinds operational guide](PathKinds.md) — using the six `path_*`
  kinds: virtual paths, validate, smoke, `path_run` (tests and probes),
  promote, wiring, and [forcing a reload for the intended consumer](PathKinds.md#force-the-reload-and-verify-consumer-access).
- [Testing and execution](Testing.md) — choosing a runner, authoring and
  running tests, exit codes, running a task directly, documentation during
  promotion.
- [Documentation lookup and the ScoutCoder: convention](Documentation.md) —
  the help_* discovery loop and the documentation-improvement comment
  convention.

## Examples from the README

```ruby
require './workflow'

repos = ScoutCoder.job(:help_list_repos).run

docs = ScoutCoder.job(:help_list_repo_documents, nil,
  repo: 'scout-gear'
).run

text = ScoutCoder.job(:help_get_repo_document, nil,
  repo: 'scout-gear',
  document: 'user/Cookbook.md'
).run

entities = ScoutCoder.job(:list_entities).run

listing = ScoutCoder.job(:list_tasks, nil,
  workflow: 'ScoutCoder'
).run
```

```bash
scout workflow task ScoutCoder help_list_repos
scout workflow task ScoutCoder help_workflow \
  --workflow ScoutCoder
```
