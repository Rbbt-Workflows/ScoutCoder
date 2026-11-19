# Layout and documentation sources

Repository layout of the ScoutCoder checkout, the `share/` authoring-drafts
convention, and how documentation repositories are resolved.

## Documentation lookup sources and repo resolution

ScoutCoder's documentation lookup covers both the core Scout ecosystem and
any installed Scout workflow. It indexes the documentation available in
installed workflows, including their `README.md`, `doc*/`, and `research/`
directories, which follow the same conventions as Scout repositories, plus a
fixed list of Scout repository checkouts.

The fixed list (`REPOS` in `lib/ScoutCoder/tasks/documentation.rb`) is:
`scout-essentials`, `scout-gear`, `scout-camp`, `scout-rig`, `scout-ai` —
note that **scout-ai is listed last in the code**; earlier README text
listed it fourth (cosmetic order difference, corrected here).

Repository resolution (`documentation.rb#repo_dir`), in order:

1. a path map under the Scout root named `<repo>` with `-` → `_` plus the
   `_lib` suffix (e.g. `scout_gear_lib`), when it exists;
2. otherwise `~/git/<repo>` when that directory exists;
3. otherwise the repo loaded as a workflow with network autoinstall
   disabled, with the checkout root derived from the workflow `libdir`
   (the parent directory when `libdir` ends in `lib`, `libdir` itself
   otherwise);
4. otherwise an installed gem of that name.

So "local clones under `~/git`" is **one branch of the chain, not the whole
story**; in environments where `~/git` does not exist, resolution falls to
the path-map and require_workflow branches. Names matching no branch raise
a controlled `ParameterException` ("Unknown repo or workflow: <name>").

## Repository layout

- `workflow.rb` - workflow entrypoint. It requires the lib task files and
  re-extends the global `::LiveWorkflow` module, which loads authoring
  drafts under `share/` (entity drafts before property drafts). It does not
  load any built-in entity tree: `lib/ScoutCoder/entity/` is **not present
  in this checkout** (earlier documentation said it "exists but is empty" —
  corrected), and `workflow.rb` requires no entity or entity-property files.
  When a built-in entity tree is added, load its entity files before
  re-extending LiveWorkflow and its property files after it, so every
  entity extend precedes property registration from either source.
- `lib/ScoutCoder/` - shipped functionality: task definitions under
  `lib/ScoutCoder/tasks/`, the entity-authoring support consumed by
  `list_entities` (`tasks/entity_tools.rb`), and the shared runner/support
  modules (`test_file_support.rb`, `probe_support.rb`,
  `python_task_support.rb`; the legacy task-test and helper-test supports
  were retired in round 13, and the two exported runner task files
  (`test_runner_tools.rb`, `probe_tools.rb`) were deleted in round 14 —
  their runners live on only as these
  support modules behind the `path_run` custom operation). The
  built-in entity tree under `lib/ScoutCoder/entity/` is not present.
- `share/` - the authoring-drafts convention. `share/tasks/`,
  `share/helpers/`, `share/entities/` and `share/entity_properties/` hold
  draft definitions loaded live by Scout-gear's `LiveWorkflow` on every
  workflow reload, in ScoutCoder's own checkout and in any other workflow
  that extends it. **In this checkout only `share/tasks/` and `share/probes/`
  exist (both empty); `share/helpers/`, `share/entities/`,
  `share/entity_properties/` and `share/test/` are absent, not empty.**
  LiveWorkflow tolerates missing or empty share subdirectories (see
  [LiveWorkflow.md](LiveWorkflow.md) § "Exclusions and tolerance"), so
  extending remains valid and is effectively a no-op here today.
- `share/test/` - test-file drafts, including the conventional `task/`,
  `helper/`, `entity/`, `entity_property/`, `python_task/` and
  `integration/` tiers. They are never loaded by LiveWorkflow; the
  `test_file` path kind and `path_run` own their lifecycle. (The directory
  is absent in this checkout today; it is created when the first test draft
  is written.)
- `share/probes/` - probe snippets (round 12): unsandboxed, one-off Ruby
  investigations of the Scout framework itself, managed by the `probe` path
  kind and executed by `path_run` (`kind: "probe"`). Never loaded by
  LiveWorkflow and never
  executed by any generic path operation.
- `share/entity/` - identifier TSVs (`<entity>.identifiers.tsv`) written by
  the entity-authoring flow. Data, not code: they are registered by the
  generated entity definition and never loaded as Ruby. (Also absent today;
  created on first use.)
- `test/` - the unit-test tree for the shipped code, following the Scout
  convention `test/ScoutCoder/...` mirroring `lib/ScoutCoder/...`. Built-in
  task tests live at `test/ScoutCoder/tasks/test_<file>.rb`.
- `research/` - non-authoritative notes shared between agents and
  executions.
- `doc/` - this tree: `doc/user/` (agent-facing usage) and `doc/developer/`
  (this file). The README remains the task reference (`# Tasks` entries).
