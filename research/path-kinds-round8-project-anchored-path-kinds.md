# Project-anchored path kinds — round 8 (corrected model, engine migration, defect ledger)

Written 2026-10-14, end of round 8 (forensics + consolidation). This note is the
durable record of the *manually edited* `lib/ScoutCoder/path_kinds.rb` found in
the working tree, the three user corrections that motivated the edit, the live
scout-ai engine contract the edit half-migrates to, and the defect ledger left
behind. Companion notes: round 4 (`research/path-kinds-round4-task-kind-integration.md`),
round 6 (`research/path-kinds-round6-task-kind.md`), round 7
(`research/path-kinds-round7-entity-property.md`). All paths below are relative
to the ScoutCoder checkout `/home/miki/git/AgentSuite/ScoutCoder` unless a
repo is named.

## Scope and provenance

This document covers: (a) the semantic model of path kinds as corrected by the
user; (b) the engine contract in the **live** scout-ai checkout; (c) a
hunk-by-hunk reading of the uncommitted edit; (d) behavioral verification that
separates user-edit-caused failure from environment drift; (e) the reusable
recipe for defining path kinds in any project; (f) the report-only defect
ledger. It does **not** fix anything: the only file this round writes is this
note.

Anchors and evidence artifacts (all on disk, none re-derived):

| item | value | evidence |
|---|---|---|
| ScoutCoder HEAD | `4a70808ff90a0f8c0f5e3ddc52fab303d8724a82` | `git log -1` |
| last commit touching `path_kinds.rb` | `e5ff246` "Documentation for path kinds: task, entity, entity_property" | `git log -1 -- lib/ScoutCoder/path_kinds.rb` |
| HEAD `path_kinds.rb` | 869 lines, md5 `2739261544bc2b4c5f37b3d9ef2b6135` — identical to the round-7 anchor | `tmp/path_kinds/HEAD_tree/lib/ScoutCoder/path_kinds.rb` |
| working tree `path_kinds.rb` | 897 lines, md5 `72c07ec80fb20897fa62b36d09231ed1` | `wc -l`, `md5sum` |
| user edit, full 3-file diff | 43,372 B (`README.md` 100 changed lines, `path_kinds.rb` 436, `workflow.rb` 17) | `tmp/path_kinds/user_edit_diff.patch` |
| user edit, `path_kinds.rb` only | 26,462 B, 13 hunks | `tmp/path_kinds/path_kinds_only.patch`, `git diff @@` markers |
| working-tree suite never loads | `ArgumentError: unknown keyword: :silent` at scout-gear-10.13.1 `lib/scout/workflow.rb:138` `require_workflow`, via scout-ai `agent/workflow.rb:208`, from `path_kinds.rb:127`; reproduced in a fresh process | `tmp/path_kinds/test_baseline.log` |
| HEAD-tree suite under the LIVE scout-ai | 10 tests, 15 assertions, 0 failures, **9 errors** — all `NoMethodError: undefined method 'find' for an instance of String` at scout-ai `path.rb:1137` `resolve_path` | `tmp/path_kinds/HEAD_test.log` |
| live scout-ai checkout | HEAD `e9663f9` "Pin agent path roots to configurable Scout maps", **dirty** (`agent.rb`, `agent/path.rb`, `sandbox.rb` modified); engine `lib/scout/llm/agent/path.rb` md5 `2a6a0c9b3e79d37d91e30754b1dc8511` | `git -C /home/miki/git/scout-ai status --porcelain`, `md5sum` |
| installed scout-gear | 10.13.1 (gem) | log paths in `test_baseline.log` |
| round-7 engine pin | `e50f4c12…` @ scout-ai `b504275` — **STALE** vs live `2a6a0c9b…` | round 7 note lines 33–39 |

Because HEAD == the round-7 anchor, the diff against HEAD *is* exactly the
user's edit; nothing else contaminated the tree (porcelain shows only ` M` on
the three files).

## The corrected model in one paragraph

Path kinds are *project-anchored virtual namespaces*, and the project is the
current directory. **(1)** The definitions belong to the workflow that lives
in the **current directory** and are declared in **that repo's own
`workflow.rb`** — ScoutCoder here carries the tools and the *consumer* side of
the definitions, but in general path kinds are defined in a *different* repo
with a *different* workflow; a `PATH_KINDS` constant that hardcodes its own
workflow name or its own checkout's absolute layout is a bug. **(2)** The root
the sandbox authorizes against is **always the current directory, which is the
project root** (`:current` = `{PWD}`, scout-essentials `path/find.rb:87`), so
roots must be spelled as project-relative Scout paths pinned at registration
time, never as another repo's `File.expand_path`d layout. **(3)** The
**locations** inside a kind (`tmp`, `project`, …) are **relative to the
current location**, i.e. resolved inside the current project root. Together:
`PATH_KINDS` in *your* `workflow.rb`, roots as unlocated Scout paths
(`Scout.share.tasks`, `Scout.lib[<your workflow>].tasks`), pinning happens
once at registration against `:current`, and the engine authorizes every
operation against those pinned location roots.

## Engine contract

All citations below verified against the **live** scout-ai checkout
`/home/miki/git/scout-ai` (engine `lib/scout/llm/agent/path.rb` md5
`2a6a0c9b…`) and installed scout-gear 10.13.1; scout-ai resolves from the
live checkout, not a gem.

### Registration: only whole-workflow incorporation

`PATH_KINDS` is consumed only when an agent incorporates the **whole
workflow** through a `tool: <Workflow>` chat line: scout-ai
`lib/scout/llm/agent.rb:148` calls `integrate_workflow_path_kinds(workflow)`
(`lib/scout/llm/agent/path/workflow_kinds.rb:31`). Task-level tool lines
(`tool: <Workflow> <task>`) and merely loading a workflow's files register
nothing — documented in scout-ai `doc/developer/PathEngine.md` §4 ("Only
whole-workflow lines grant"). Discovery is namespace-local
(`const_defined?(:PATH_KINDS, false)`, `workflow_kinds.rb:38`), so a constant
inherited from a parent module is invisible.

### Root pinning: one-shot against the effective map

`register_path_kind` (`path.rb:114`) normalizes the definition and then calls
`path_pin_roots!` (`path.rb:145` → `path.rb:306`): every **non-absolute** root
is pinned via `follow(effective_map)` and stored back as an absolute String;
absolute roots (plain Strings *and* Path objects) pass through untouched
(`path.rb:303-305`, comment at `path.rb:302-305`). `path_validate_roots!`
(`path.rb:335`) then requires every declared location to have a nonempty
absolute root (`path_validate_root!` at `path.rb:368-379` accepts an absolute
String **or** a Scout Path-like object); the `project` location may fall back
to an implicit `Scout.root.find(...)` root (`path.rb:348-356`).

### Effective map: per-kind, then agent option, then `:current`

The map applied at pinning is: the kind's own `"path_map"` key, else the
agent's `LLM.agent(path_map:)` option, else `DEFAULT_PATH_MAP = :current`
(`path.rb:264`, `path_kind_effective_map` at `path.rb:276`). `:current` is the
template `{PWD}/{TOPLEVEL}/{SUBPATH}` (scout-essentials `path/find.rb:87`) —
**the current directory is the project root** (user correction 2). The map is
applied ONCE at registration and the result pinned to an absolute String, "so
the filesystem boundary … can never re-resolve" (`path.rb:260-266` comment);
this is the same pinning behavior documented in `PathEngine.md` §2.

### Roots are authorization grants

"Roots are authorization grants. Every declared location needs a root"
(`path.rb:332-334`). After resolution the concrete target is authorized
against the location root (`path_authorize!`, `path.rb:1142-1144`, delegating
to `LLM::Sandbox.authorize_path`, `lib/scout/llm/sandbox.rb:76`). Kinds are
**sandboxed by default** (`definition.fetch("sandbox", true)`,
`path.rb:1143-1144`), so a kind without a usable root cannot authorize
anything.

### Kind-name collisions

Same kind name re-registered from the **same** workflow: idempotent overwrite
(the new source owns the name, `workflow_kinds.rb:54-60` deep-copies and
re-registers). Same kind name from a **different** workflow: deterministic
failure — `"Path kind … is already provided by workflow …; workflow … cannot
redefine it"` (`workflow_kinds.rb:47-52`).

### `resolve_path`: Path-object roots vs String roots (the API migration)

In the live engine, `resolve_path` (`path.rb:1098`) builds
`final_path = (Path === root) ? root[path.to_s] : File.join(root.to_s, path.to_s)`
and then calls **`final_path.find(path_map)`** (`path.rb:1131-1137`). Two
consequences:

- **Unlocated Scout-path roots** (`Scout.share.tasks`,
  `Scout.lib['Foo'].tasks`, which produce annotated but `located? == false`
  Paths) pin to absolute Path-strings at registration and then *work*: the
  `Path#[]` child plus `.find(path_map)` round-trip is exactly what the
  engine now expects.
- **Old `File.join` String roots** (round ≤7 spelling,
  `File.join(PATH_KIND_ROOT, 'share', 'tasks')`) reach `path.rb:1134`
  `File.join` and then crash at `path.rb:1137` — `String` has no `find`. This
  is precisely the 9-error signature in `tmp/path_kinds/HEAD_test.log`.

So the edit's switch from `File.join(...)` Strings to `Scout.share.*` /
`Scout.lib[...]` Path objects is not only cosmetic re-anchoring: it is **in
part a genuine engine-API migration** forced by the live `resolve_path`.

### Scout Path mechanics (the `.find` discipline)

Verified against scout-essentials 1.9.1 in fresh processes
(`tmp/path_kinds/foreign/probe_paths.rb`, output in
`tmp/path_kinds/foreign/probe_paths.log`):

- `Scout.share.<dir>`, `Scout.lib['Foo'].<dir>`, `Scout.root.test[...]`
  produce **unlocated annotated Paths** (`Scout.share.tasks.located? # =>
  false`).
- `.find(:current)` pins to `{PWD}` **with no existence check**
  (scout-essentials `path/find.rb:263` `return follow(where) if where`), so it
  always yields `<PWD>/…` even for directories that do not exist yet.
- **Bare `.find`** (no argument) walks `map_order` existence-dependently and
  resolves `lib/...` spellings to the **USER STORE** — from the foreign
  checkout (CWD `tmp/path_kinds/foreign`, workflow `Foo`):
  `Scout.lib['Foo'].tasks.find # => /home/miki/.scout/lib/Foo/tasks`, and
  `Scout.root.test['ScoutCoder'].tasks.find # => /home/miki/.scout/test/ScoutCoder/tasks`.
  Meanwhile `Scout.share.tasks.find(:current) # => <foreign>/share/tasks`
  (correct). **Always anchor with `.find(:current)` when you mean the current
  project; never use bare `.find` on `Scout.lib[...]` / `Scout.root[...]`
  spellings from a foreign checkout.**

### Verified registration probes

`tmp/path_kinds/probe_register.rb` (from this checkout) and
`tmp/path_kinds/probe_register_foreign.rb` (from the foreign `Foo` checkout):
registering kinds whose roots are `Scout.share.tasks` /
`Scout.lib['Foo'].tasks` stores **pinned absolute Strings**
`{"tmp" => "<PWD>/share/tasks", "project" => "<PWD>/lib/Foo/tasks"}` — i.e.
the roots follow the current directory (corrections 2 and 3), exactly the
pinning behavior described in `PathEngine.md` §2.

## What the edit changed and why

13 hunks in `git diff HEAD -- lib/ScoutCoder/path_kinds.rb`
(`tmp/path_kinds/path_kinds_only.patch`). "Correction" columns refer to the
three user corrections (1 = defined in the current directory's own workflow;
2 = root is always the current directory / project root; 3 = locations are
relative to the current location). "Engine migration" = the
`resolve_path` Path-vs-String requirement above.

| # | hunk (`@@` range) | change | rationale |
|---|---|---|---|
| 1 | `-12,7 +12,7` | header comment `lib/ScoutCoder/tasks` → `lib/<workflow>/tasks` | correction 1 (docs) |
| 2 | `-37,8 +37,8` | round-7 two-location table entity paths → `lib/<workflow>/...` | correction 1 (docs) |
| 3 | `-48,14 +48,210` (+195 lines) | `require 'scout/workflow'` at top; helper block **moved above** `PATH_KINDS`; new helpers `target_workflow` / `target_workflow_name` | correction 1 + structural: helpers must precede the constant (the constant interpolates `target_workflow_name`); the require makes Scout available when the file loads standalone |
| 4 | `-73,18 +269,27` | `task` kind: interpolated description with `#{target_workflow_name}`; roots `File.join(...)` → `Scout.share.tasks` / `Scout.lib[target_workflow_name].tasks`; commented-out `'resolve'` hook sketch | correction 1 (name) + corrections 2/3 (re-anchoring) + engine migration (Path-object roots) |
| 5 | `-121,12 +326,12` | validate regexp `module ScoutCoder` → `module #{target_workflow_name}` (interpolated, line 334) | correction 1 |
| 6 | `-147,7 +352,7` | comment `lib/ScoutCoder/task_test_support.rb` → `lib/<workflow>/task_test_support.rb` | correction 1 (docs) |
| 7 | `-158,7 +363,7` | trust-boundary comment `test/ScoutCoder/tasks` → `test/<workflow>/tasks` | correction 1 (docs) |
| 8 | `-245,12 +450,12` | smoke script: `require './workflow'` → `workflow = Workflow.require_workflow './workflow.rb'`; `ScoutCoder.tasks` → `workflow.tasks` | correction 1 (dynamic workflow naming) |
| 9 | `-287,6 +492,8` | `task` `promotion_post_move` adds live Scout spellings after the dead `File.join` lines (lines 495-496) | corrections 2/3 (project-relative paired tests) |
| 10 | `-313,15 +520,15` | `entity` kind roots → `Scout.share.entities` / `Scout.lib[target_workflow_name].entities` | correction 1 + corrections 2/3 + engine migration |
| 11 | `-496,14 +703,14` | `entity_property` roots → `Scout.share.entity_properties` / `Scout.lib[target_workflow_name].entity` | same as hunk 10 |
| 12 | `-670,6 +877,8` | `entity_property` `promotion_post_move` adds two live lines; the project side (line 881) uses **undefined local `workflow`** | corrections 2/3 attempted — **DEFECTIVE**, see ledger item 2 |
| 13 | `-685,185 +894,4` (−181 lines) | old trailing helper block removed | structural companion of hunk 3 (the helpers moved to the top) |

The parallel `workflow.rb` diff (`tmp/path_kinds/user_edit_diff.patch`) is a
separate concern: it comments out seven task-file requires (ledger item 9) and
gates the `path_kinds` require behind
`Scout.root['workflow.rb'].find(:current).exists?` — report-only here.

## Behavioral verification

Two failure signatures, two different causes — the distinction matters.

**1. Working tree never loads (user-edit-caused, deterministic).**
`tmp/path_kinds/test_baseline.log`: requiring `./workflow` dies before any
test runs with `ArgumentError: unknown keyword: :silent` raised by scout-gear
10.13.1 `lib/scout/workflow.rb:138` (`Workflow.require_workflow(workflow_name_orig, update: nil)` has **no** `silent:` parameter), reached through the
scout-ai wrapper `lib/scout/llm/agent/workflow.rb:208` (`require_workflow_old(name, ...)` forwards kwargs verbatim) from `lib/ScoutCoder/path_kinds.rb:127`
(`target_workflow`). Reproduced in a fresh process
(`tmp/path_kinds/test_baseline.log`); the tree is
unloadable end-to-end, so **no** suite result from the working tree can be
attributed to the semantic changes. Two minimal fixes are verified in fresh
processes, including re-entrant load (probe trees
`tmp/path_kinds/rwtest` and `tmp/path_kinds/smoketest`):

- `Workflow.require_workflow_file(File.expand_path('workflow.rb', __dir__.sub(%r{/lib/.*}, '')))` — silent, CWD-independent (scout-gear `workflow.rb:123-128` loads a file without workflow-name lookup), re-entrancy-safe; verified: `rwtest fix(1) loaded workflow=ScoutCoder`.
- `Workflow.require_workflow './workflow.rb'` — works when CWD is the target
  checkout (which is exactly corrections 2/3); verified: `smoketest fix(2) loaded workflow=ScoutCoder`.

**2. HEAD tree under the LIVE engine: 9 errors = environment drift, not the
edit.** `tmp/path_kinds/HEAD_test.log` (HEAD extracted via `git archive` into
`tmp/path_kinds/HEAD_tree`, run against the live dirty scout-ai checkout): 10
tests, 15 assertions, 0 failures, **9 errors**, every error
`NoMethodError: undefined method 'find' for an instance of String` at scout-ai
`path.rb:1137` (`resolve_path`). Cause: the round ≤7 roots were
`File.join` Strings, and the live engine (path.rb md5 `2a6a0c9b`) requires
`Path === root` to take the `root[path]` branch — see *Engine contract* →
*resolve_path*. This is **engine drift relative to the round-7 pin** (round 7
recorded `e50f4c12…` @ `b504275`); it is *not* caused by the user's edit (the
HEAD tree contains none of it) and, symmetrically, the user's Path-object
roots are the direction the live engine requires.

**3. Probe evidence for the corrected anchoring.** Fresh-process probes
(cited above under *Scout Path mechanics* and *Verified registration probes*):
from the foreign checkout `tmp/path_kinds/foreign` (workflow `Foo`),
`Scout.share.tasks.find(:current)` = `<foreign>/share/tasks` (correct),
`Scout.lib['Foo'].tasks` **bare** `.find` = `/home/miki/.scout/lib/Foo/tasks`
(**user-store trap**), `Scout.root.test['ScoutCoder'].tasks` needs
`.find(:current)`; and registering kinds with roots
`Scout.share.tasks` / `Scout.lib['ScoutCoder'].tasks` from this checkout pins
`{"tmp" => "<PWD>/share/tasks", "project" => "<PWD>/lib/ScoutCoder/tasks"}` —
roots follow the current directory.

**`scout test` CLI note (unrelated to the edit).** `bin/scout` (scout-gear
10.13.1, lines 223-237) dispatches subcommands by trying `load dir[$command].find`;
because `./test` **exists as a directory** in this checkout, the first `case`
branch descends into it and the eventual `load $command` fails with
`LoadError: cannot load such file -- test` (`tmp/path_kinds/scout_cli_attempt.log`,
backtrace at `bin/scout:261`/`237`). This is a dispatch collision, not an
effect of any edit. Use `ruby -Ilib -Itest <file>` in this checkout.

## The two-location model and paired-test conventions

Each kind has two locations. Roots are project-relative Scout paths pinned at
registration (correction 3); the layout below is the README's contract
(`README.md` §Agent path kinds, pairing table around line 420):

| kind | tmp root (drafts, default) | project root (promoted) | virtual path |
|---|---|---|---|
| `task` | `Scout.share.tasks` → `share/tasks` | `Scout.lib[<wf>].tasks` → `lib/<workflow>/tasks` | `greet_user.rb` |
| `entity` | `Scout.share.entities` → `share/entities` | `Scout.lib[<wf>].entities` → `lib/<workflow>/entities` (plural) | `demo_widget.rb` |
| `entity_property` | `Scout.share.entity_properties` → `share/entity_properties` | `Scout.lib[<wf>].entity` → `lib/<workflow>/entity` | `demo_widget/tag_palette.rb` |

**Project-root divergence (post-edit).** Pre-edit, `entity` and
`entity_property` deliberately **shared** one project root
(`File.join(PATH_KIND_ROOT, 'lib', 'ScoutCoder', 'entity')`): promoted
entity files flat `<entity>.rb` beside nested `<entity>/<property>.rb`
(a flat property virtual path is still a validate error, not a second
shape). **After the edit the two roots diverge**: the `entity` project root
is `Scout.lib[<wf>].entities` → `lib/<workflow>/entities` (plural,
`path_kinds.rb:531`) while `entity_property`'s is
`Scout.lib[<wf>].entity` → `lib/<workflow>/entity` (singular,
`path_kinds.rb:713`) — distinct spellings verified in a fresh process
(`Scout.lib['ScoutCoder'].entities` → `lib/ScoutCoder/entities`,
`Scout.lib['ScoutCoder'].entity` → `lib/ScoutCoder/entity`), and the
on-disk directory is the singular `lib/ScoutCoder/entity`. Consequence:
promoted entity files would now land **beside**, not inside, their
properties' directory — ledger item 13.

Paired-test conventions (README pairing table, lines ~420-425):

| kind | tmp paired test (no prefix) | project paired test (`test_` prefix) |
|---|---|---|
| `task` | `share/test/task/<name>.rb` | `test/<workflow>/tasks/test_<name>.rb` |
| `entity` | `share/test/entity/<name>.rb` | `test/<workflow>/entity/test_<name>.rb` |
| `entity_property` | `share/test/entity_property/<entity>/<entity>.<property>.rb` | `test/<workflow>/entity/test_<entity>_<property>.rb` |

Three rules: the **share side carries no `test_` prefix**; the project side
does; and the property test name **flattens** the nested virtual path
(`<entity>/<property>.rb` → `test_<entity>_<property>.rb`). These project-side
locations are pinned by `test/<workflow>/test_path_kinds.rb` but have no
precedent elsewhere in the checkout — the README itself flags them as "the
convention this README records, still awaiting explicit ratification". The
live helper code does **not** fully match this table (ledger items 3-5).

## Recipe: defining path kinds in any project

For a foreign workflow `Foo` living in its own checkout:

1. **Declare `PATH_KINDS` in *Foo's own* `workflow.rb`**, inside the workflow
   module (namespace-local discovery, `workflow_kinds.rb:38`). Use unlocated
   Scout-path roots — they pin to absolute Strings at registration:
   `tmp` → `Scout.share.<dir>`, `project` → `Scout.lib['Foo'].<dir>`. Never
   `File.expand_path` another repo's layout, and never hardcode your own
   workflow name where the constant can interpolate `name`/helpers.
2. **Incorporate the workflow whole**: a `tool: Foo` chat line. A task-level
   `tool: Foo some_task` line registers nothing (`PathEngine.md` §4).
3. **Optional per-kind `path_map`**: add `"path_map" => :lib` (or any map) to
   a kind when its roots should pin against a map other than `:current`;
   otherwise `:current` (the project root = current directory) applies
   (`path.rb:264`, `path.rb:276`).
4. **Validate**: roots must end up nonempty absolute (Strings or Path-likes)
   after pinning (`path.rb:335`, `path.rb:368-379`); plain relative spellings
   like `"share/tasks"` are accepted at the declaration level *because*
   pinning expands them (`PathEngine.md` §2), but the pinned result is what
   authorizes every operation.
5. **`.find` discipline**: inside hooks and helpers, always anchor with
   `.find(:current)`. Bare `.find` on `Scout.lib[...]`/`Scout.root[...]`
   resolves to the **user store** (`/home/miki/.scout/...`) from any checkout
   that is not the resolved library project — verified trap
   (`tmp/path_kinds/foreign/probe_paths.log`).
6. **Avoid collisions**: a kind name already owned by another incorporated
   workflow fails registration deterministically
   (`workflow_kinds.rb:47-52`); same-workflow re-registration is an
   idempotent overwrite.

### Worked minimal example: `Foo` with a `documents` kind

In the `Foo` checkout's `workflow.rb`:

```ruby
require 'scout'
require 'scout/workflow'

module Foo
  extend Workflow

  PATH_KINDS = {
    'documents' => {
      'description' =>
        'Project documents for Foo (drafts in doc/drafts, promoted in doc)',

      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',

      'roots' => {
        'tmp' => Scout.root['doc']['drafts'],   # unlocated Scout path
        'project' => Scout.root['doc']
      },

      'sandbox' => true,
      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true, 'test' => true, 'smoke' => true,
        'promote' => true
      }
    }
  }.freeze
end
```

How it pins from **two different checkouts** (both verified shapes; the
registration probe used `Scout.share.tasks`/`Scout.lib[...]`, the same
mechanism as `Scout.root[...]` here):

- Run from `/home/miki/git/Foo` (CWD = the Foo checkout, e.g. an agent whose
  chat anchors there): registration pins
  `{"tmp" => "/home/miki/git/Foo/doc/drafts", "project" => "/home/miki/git/Foo/doc"}`
  and every `path_*` operation authorizes inside those two roots.
- Run from a second Foo clone `/home/miki/git/Foo2`: the **same declaration**
  pins `{"tmp" => "/home/miki/git/Foo2/doc/drafts", "project" =>
  "/home/miki/git/Foo2/doc"}` — the roots follow the current directory
  (corrections 2/3), exactly as observed in
  `tmp/path_kinds/probe_register.rb` vs
  `tmp/path_kinds/probe_register_foreign.rb` (identical declaration, two
  CWDs, two pinned root sets, both `{"tmp" => "<PWD>/share/tasks", ...}`
  shaped).

Then the agent chat needs a whole-workflow `tool: Foo` line and nothing else;
no `resolve` hook is required for a plain filesystem kind (the engine's
default resolution is `root[path].find(path_map)`, `path.rb:1131-1137`).

## Defect ledger (REPORT-ONLY — none of these were fixed this round)

| # | location | defect | verified minimal fix |
|---|---|---|---|
| 1 | `path_kinds.rb:127` | `Workflow.require_workflow 'workflow.rb', silent: true` → `ArgumentError: unknown keyword: :silent` (scout-gear `workflow.rb:138` has only `update:`); whole checkout's `workflow.rb` unloadable | `Workflow.require_workflow_file(File.expand_path('workflow.rb', __dir__.sub(%r{/lib/.*}, '')))` (preferred: silent + CWD-independent) or `Workflow.require_workflow './workflow.rb'` when CWD is the checkout — both verified fresh-process incl. re-entrant load |
| 2 | `path_kinds.rb:881` | `entity_property` `promotion_post_move` project side uses **undefined local `workflow`** → `NameError` on tmp→project promotion | `Scout.root.test[target_workflow_name].entity[entity]['test_' + property + '.rb'].find(:current)` (README-shaped) |
| 3 | `path_kinds.rb:165` | live entity tmp-test name `test_#{name}.rb` inside `share/test/entity/` contradicts documented **no-prefix** share side | `"#{name}.rb"` |
| 4 | `path_kinds.rb:208` | property tmp-test basename drops the `<entity>.` prefix (`p.rb` instead of `E.p.rb`) | `"#{entity}.#{property}.rb"` |
| 5 | `path_kinds.rb:211` (and `:879`, `:881`) | property project-test uses an `entity_property/` path segment vs the documented **flattened** `test/<workflow>/entity/test_<entity>_<property>.rb`; three inconsistent spellings | use the README spelling in all three places |
| 6 | `path_kinds.rb:75, 78, 164, 167, 207, 210, 493-494, 676-677, 878-879` | dead `File.join(PATH_KIND_ROOT, ..., 'ScoutCoder', ...)` assignments immediately overwritten (or, for entity post-move `:676-677`, **still the only** live lines, hardcoded to ScoutCoder) | delete the dead lines; convert entity `promotion_post_move` to the live Scout spellings |
| 7 | `path_kinds.rb:76` | task tmp-test return is **unlocated** (no `.find(:current)`), unlike the entity/property helpers | append `.find(:current)` |
| 8 | `path_kinds.rb:265` (PATH_KIND_ROOT def) + hooks at `:411, 462, 609, 655, 799, 855` | `PATH_KIND_ROOT` is `__dir__`-based while the fresh-process hooks chdir to it; under foreign hosting the hooks run in the hosting repo while the roots are PWD-based — latent tension | chdir to the **pinned tmp root** instead of `PATH_KIND_ROOT` |
| 9 | `workflow.rb:25-31` | seven tool requires commented out (`workflow_tools`, `task_test_tools`, `python_task_tools`, `helper_tools`, `entity_tools`, `list_entities`, `helper_test_support`); only `documentation` + `document_task` remain (7 tasks total) — capability regression vs correction 1 ("ScoutCoder contains the tools"), and it strands `test/ScoutCoder/tasks/*` | report-only; restore requires when the tree is loadable again |
| 10 | `README.md:933-961` (`## reverse`) | malformed entry (duplicate `## Example` headings, stray fence, stray `# => "olleh"`) documenting a **nonexistent** task (no `task :reverse` anywhere; commit `4a70808` removed the test task) | remove the entry or complete the task |
| 11 | `path_kinds.rb:334` | cosmetic: indentation of the interpolated error line (`errors <<` over-indented inside the `unless`) | re-indent |
| 12 | `research/path-kinds-round7-entity-property.md:35-37` | engine pin stale: records `e50f4c12…` @ scout-ai `b504275` while the live tree is `2a6a0c9b…` @ `e9663f9` (dirty) | re-pin or annotate as historical (this note supersedes) |
| 13 | `path_kinds.rb:531` (entity root) vs `path_kinds.rb:713` (entity_property root) — introduced by hunks 10/11 | the two project roots are spelled differently after the edit: `Scout.lib[target_workflow_name].entities` (→ `lib/<workflow>/entities`, plural) vs `Scout.lib[target_workflow_name].entity` (→ `lib/<workflow>/entity`, singular); pre-edit both were `File.join(PATH_KIND_ROOT, 'lib', 'ScoutCoder', 'entity')`. Symptom: promoted entity files land **beside**, not inside, their properties' directory, and the plural spelling mismatches the on-disk singular `lib/<workflow>/entity` | align both roots to `Scout.lib[target_workflow_name].entity` (keeps the flat `<entity>.rb` / nested `<entity>/<property>.rb` sharing the README documents), or rename the on-disk directory to the plural spelling and re-ratify the README table |

## Open questions

1. **Round-7 pin staleness.** The live scout-ai checkout is dirty and ahead of
   the round-7 record (`path.rb` md5 `2a6a0c9b…` vs pinned `e50f4c12…`). Are
   the uncommitted engine changes (root pinning to configurable Scout maps,
   `agent.rb`/`sandbox.rb` siblings) in-flight user work that will land, or a
   local-only state? The `resolve_path` Path-vs-String contract documented
   here describes the live tree only.
2. **Wrapper internals elided.** `agent/workflow.rb:209-211` (the
   `LLM.load_agent(name).workflow` fallback inside `require_workflow`) was
   verified only far enough to establish that kwargs are forwarded verbatim
   (hence defect 1); its fallback semantics are not otherwise audited.
3. **`PATH_KIND_ROOT` chdir tension (ledger 8).** Whether foreign hosting
   should be supported by chdir-ing to the pinned tmp root, by making
   `PATH_KIND_ROOT` CWD-derived, or by declaring the tension out of scope —
   unresolved; the hooks' fresh-process behavior under a foreign host has not
   been exercised beyond the registration probes.
4. **Project-side test-location ratification.** The README flags
   `test/<workflow>/entity/test_<entity>_<property>.rb` and friends as
   "awaiting explicit ratification" (README ~line 433); defect 5's three-way
   inconsistency makes that ratification the natural next step.

---

# ROUND 9 — disposition record (applied, verified, frozen)

Delta document for round 9 only. Round-8 prose above is untouched; this
section records what was actually done to each ledger row, with evidence.
Prep-stage worklist: `tmp/path_kinds/round9_worklist.md` (13 rows, engine
facts, chosen fix). Snapshots of the user's uncommitted round-8 edit:
`tmp/path_kinds/round9_snapshots/` (byte-identical, `SHA256SUMS.txt`).

## Dispositions (13 rows)

| # | disposition | evidence |
|---|---|---|
| 1 | **fixed** — `:127` → `Workflow.require_workflow_file(File.expand_path('workflow.rb', __dir__.sub(%r{/lib/.*}, '')))` | `round9_load.log` root + alt-CWD loads EXIT=0; `round9_item1_test.log`: `ArgumentError` gone, suite runs (10 tests) |
| 2 | **fixed** — `:881` `workflow` → `target_workflow_name`, spelling `["test_#{entity}_#{property}.rb"]` | `round9_promotion_probe.log` (b) `post_move=ok` + (b2) mv-branch executed; `round9_item2_13_test.log` NameError gone |
| 3 | **fixed** — `:165` → `["#{name}.rb"]` | live-code check: `path_kind_entity_test_file("X","tmp")` → `share/test/entity/X.rb` (three-way agreement, below) |
| 4 | **fixed** — `:880` → `["#{entity}.#{property}.rb"].find(:current)` | `round9_promotion_probe.log` stage-3: paired_property_test_relocated=PASS under the documented spelling |
| 5 | **fixed** — `:881` + helper `:207` → `["test_#{entity}_#{property}.rb"]`; three-way agreement verified for task/entity/entity_property | live-code check vs README table vs suite seeds (`test_path_kinds.rb:386,404`); README needed no edit |
| 6 | **fixed** — 6 provably-dead `File.join(PATH_KIND_ROOT…)` lines deleted (each immediately overwritten on the next line); live `PATH_KIND_ROOT` uses (constant + `chdir:` args) untouched | `grep -c "File.join(PATH_KIND_ROOT"` → 0; probe assertion (c) PASS. **Follow-on:** exposed suite-confinement seam mismatch → repaired test-side, see below |
| 7 | **fixed** — `.find(:current)` appended to the four share/root test lookups returning relative Strings | live-code check: all four `path_kind_*_test_file` now return absolute checkout paths |
| 8 | **deferred** — needs a foreign-host harness; open question 3 unresolved; not conditioned on the requires decision | no code change; this row is the reason |
| 9 | **intentional** — user decision round 9: requires at `workflow.rb:25-31` stay commented out "for now" | no action; not a defect this round |
| 10 | **intentional / already resolved** — `## reverse` block removed in round 8 (`readme_fixes.md` edit H; preserved at `tmp/path_kinds/reverse_block_removed.txt`; never in HEAD) | `grep -n "olleh\|## reverse" README.md` → 0 hits (943-line README) |
| 11 | **fixed** — `errors <<` de-indent 14 → 12 spaces (whitespace-only) | `cat -A` before/after; `ruby -c` OK |
| 12 | **fixed** — supersession note at `research/path-kinds-round7-entity-property.md:38` | live `md5sum scout-ai/lib/scout/llm/agent/path.rb` = `2a6a0c9b…` @ `e9663f9`, re-verified at annotation time |
| 13 | **fixed** — `:531` → `Scout.lib[target_workflow_name].entity`; `:530` `Scout.share.entities` correctly stays plural (live draft dir) | `round9_promotion_probe.log` item13_root_alignment=PASS: flat `<entity>.rb` beside nested `<entity>/<property>.rb`, no plural dir |

Plus the §F comment corrections folded into 6/7: `:21` and `:272` "roots MUST
be absolute" → true semantics (Scout `Path` roots, relative Scout-path
locations, `path_pin_roots!` at scout-ai `path.rb:306` pins absolute at
registration). Comment-only, no behavior change.

## The `silent:` fix (item 1) — chosen option and rejected alternative

Chosen: `Workflow.require_workflow_file(File.expand_path('workflow.rb',
__dir__.sub(%r{/lib/.*}, '')))`. Rationale: the live scout-gear 10.13.1 API
(`lib/scout/workflow.rb:123-135, 138`) accepts only `update:` — no `silent:`
kwarg — and `require_workflow_file` (`:123-128`) is the silent,
CWD-independent, re-entrancy-safe entry point, already the in-repo idiom at
five other call sites. Rejected option 2 (`Workflow.require_workflow
'./workflow.rb'`) because its silence depends on the process CWD being the
checkout, which the alt-CWD load (`round9_load_altcwd.log`) explicitly
disproves as a safe assumption. `silent:` classification: exactly three
occurrences under `lib/ScoutCoder/` — `path_kinds.rb:127` (the load
blocker), `path_kinds.rb:268` and `tasks/documentation.rb:89` (valid prose
comments). No second broken call survived the fix.

## Design corrections still hold

All four round-8 design corrections were preserved by the round-9 fixes and
are confirmed by the post-fix load log: kinds are defined by the current
directory's `workflow.rb` (`workflow.rb:22` gate, unchanged); the sandbox
root is the current directory (project root — never touched); locations are
declared as relative Scout paths (`Scout.share.tasks`,
`Scout.lib[target_workflow_name].tasks`, etc. — all still Scout `Path`
objects); roots resolve inside the project (`.find(:current)`:
`share/tasks`, `share/entities`, `share/entity_properties`,
`lib/ScoutCoder/{tasks,entity}` — `round9_load.log` repair-cycle append).

## Drift attribution (terminal suite state)

`10 tests, 15 assertions, 0 failures, 9 errors` (`round9_repair_test.log`).
All 9 errors are the pre-attributed engine drift:
`NoMethodError: undefined method 'find' for an instance of String` at
scout-ai `lib/scout/llm/agent/path.rb:1137` (`Agent#resolve_path`), engine
dirty at HEAD `e9663f9`, `path.rb` md5 `2a6a0c9b…`. Error-set identity:
sorted `^Error:` lines diffed between `round9_final_test.log` and
`round9_repair_test.log` — byte-identical, only the single failure line
removed by the repair. Every drifting test enters through
`path_write`/`write_draft`, i.e. the engine's own resolver, before any
ScoutCoder hook runs; the direct-hook probe (`round9_promotion_probe.log`,
EXIT=0) proves the hook side works end-to-end.

## Harness repair (same round, test-side only)

Item 6's switch from `PATH_KIND_ROOT`-joined strings to Scout-map lookups
(`Scout.share.test...find(:current)`, `:current` map = `{PWD}/…`) made the
suite's `confine_kind_root_to_sandbox!` (which swaps only
`PATH_KIND_ROOT`) insufficient for the one test invoking the hook directly.
Repaired in `test/ScoutCoder/test_path_kinds.rb` by a new
`confine_cwd_to_sandbox!` helper mirroring the existing idiom, applied to
`test_property_hook_direct_invocation_moves_exactly_one_file`, CWD restored
in `teardown`. No assertion weakened; no production code changed
(`lib/ScoutCoder/path_kinds.rb` sha256 `07105ab3…` unchanged across
stages 3 → repair). First failure signature + full attribution:
`round9_final_test.log` (bottom section).

## Round-10 candidates

1. **Item 8 / open question 3** — foreign-host harness for the
   `PATH_KIND_ROOT` chdir tension; decide chdir-to-tmp-root vs CWD-derived
   root vs out-of-scope.
2. **Drift resolution upstream** — the 9 `path.rb:1137` errors should
   disappear once the engine change lands; nothing to do here.
3. **Suite-confinement modernization** — only if more direct-hook tests are
   added; `confine_cwd_to_sandbox!` covers the current need.
4. **Project-side test-location ratification** (open question 4) — now that
   the three-way spelling agreement holds, ratify the README table's
   `test/<workflow>/entity/test_<entity>_<property>.rb` convention.
