# LiveWorkflow and WorkflowReload

`LiveWorkflow` is Scout's workflow extension implemented in scout-gear at
`scout/workflow/live.rb`. A target workflow that extends it gets every
`*.rb` draft under its own `share/` loaded on each (re)evaluation of
`workflow.rb`, so tasks, helpers and entity drafts register without a
manual load block. A target workflow extends `Workflow` and the global
`::LiveWorkflow` module; the Scout-gear implementation is loaded through
the project's normal load path. ScoutCoder's `workflow.rb` re-extends this
shared Scout extension.

Load order, on every pass: `share/tasks`, `share/helpers`,
`share/entities`, `share/entity_properties` - top-level files of each
subdirectory before nested ones, lexicographic within a level, so loads are
deterministic. Entity files always precede property files, because a
property file loaded before its entity module has no module to register on
and fails loudly at load time (`Entity.extended` guards `@properties`
against being reset — `scout-gear lib/scout/entity.rb`, `extended` hook,
verified in 10.13.1 — so re-extension itself is not the failure). That
ordering is a contract, not an implementation detail. When a built-in
entity tree is present, `workflow.rb` relies on the same rule across
sources: lib entity files load, then `LiveWorkflow` loads share entity and
property drafts, then lib property files load. Thus every entity extend
precedes property registration, whether the entity or property comes from
`lib/` or `share/`.

Reload semantics. Re-extending the global `::LiveWorkflow` module fires
`self.extended`. `Workflow.require_workflow(file, update: true)`
re-evaluates `workflow.rb`, so adding or editing a draft file and reloading
the workflow picks up the change without restarting. Files are loaded with
Kernel#load, not require, so they re-execute every time. For the
loaded-but-not-re-evaluated case (a workflow object already in memory), call
`workflow.load_live_files!` explicitly; it is the same implementation as the
extended hook. Re-loading never raises on re-declaration: tasks reassign,
helpers redefine, and re-extending Entity is expected behavior.

## Workflow-level reload (reload build, steps 1-5)

`require_workflow` with `update: true` re-evaluates `workflow.rb` but does
NOT re-run its `require_relative` lines while the lib files sit in
`$LOADED_FEATURES` — that is exactly the staleness promoted or edited lib
code used to leave in a running process. ScoutCoder therefore ships a full
workflow-level reload, `ScoutCoder::WorkflowReload.reload_workflow!(root:)`
(`lib/ScoutCoder/path_kinds/workflow_reload.rb`; agent surface: the
`reload_workflow` task):

- Purge composition: every `$LOADED_FEATURES` `.rb` entry whose realpath
  falls under the realpathed target checkout root — the entrypoint
  `workflow.rb` included when it is a feature entry (child processes whose
  loader does `require './workflow'` do cache it; `require_workflow`
  itself evaluates the entrypoint with `Kernel#load` and never does).
  Framework features outside the root always stay.
- Normalization: `File.realpath` on BOTH sides — feature entry and root.
  Alias mount spellings (`/home/...` vs `/bulk/...`) and symlinked roots
  differ lexically; realpath is what collapses them (verified, step 1).
- Re-entry: after the purge, `Workflow.require_workflow(<entrypoint>,
  update: true)` re-evaluates `workflow.rb` and its `require_relative`
  lines re-fire; when the entrypoint itself was purged, a plain `require`
  re-executes it first (report mode `required` vs `re-evaluated`).
- Memo handling: re-evaluation returns the SAME workflow module object,
  so `ScoutCoder.target_workflow`'s `@@target_workflow` memo survives a
  reload untouched — the reloaded workflow IS the memoized object.
- Ruby caveat (documented, not fixed by any reload): reloading does not
  undo previous execution. Already-instantiated Step objects keep the old
  method definitions; consumers re-resolve through the module. A fresh
  process is the only full reset.
- Idempotence: safe to repeat; the second reload purges the features the
  first reload re-cached and re-fires again — correct, not a no-op.
- Silent reload bookkeeping: the helper calls `require_workflow` with
  `silent: true`, which removes the workflow's entry from
  `Workflow.workflows` just before the re-evaluation re-registers it —
  without it each reload would append a duplicate; the immediate
  re-registration restores membership, and no output difference was
  observed either way.
- Failure normalization: `reload_workflow!` rescues `StandardError` AND
  `ScriptError` and re-raises both as Scout `ParameterException` with the
  original message verbatim. The `ScriptError` arm matters in practice: a
  `SyntaxError` raised while re-evaluating a broken `workflow.rb` is a
  `ScriptError`, not a `StandardError`, and previously escaped the
  normalization raw.

Hand-authored task and helper draft files loaded by `LiveWorkflow` must wrap
declarations in the target workflow module (`module MyWorkflow ... end`),
because `Kernel#load` evaluates each file at top level. Entity and property
drafts follow their distinct module/body formats described in
[doc/user/AuthoringEntities.md](../user/AuthoringEntities.md).

## Exclusions and tolerance

- `share/test` is never loaded, in any shape; task and helper tests run in
  fresh processes instead.
- Only `*.rb` files are selected, so identifier TSVs such as
  `share/entity/<entity>.identifiers.tsv` are never loaded as Ruby.
- Missing or empty share subdirectories, and a missing `share/` itself,
  contribute nothing; extending remains valid with no `libdir`.
- Removing a draft file stops re-registering it, but the task or module it
  defined stays in memory for the process lifetime: Ruby cannot unload
  constants or methods. A fresh process clears it. Reload after removal is
  therefore tolerated (no error), not reverted.
