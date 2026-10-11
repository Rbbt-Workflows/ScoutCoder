# Round 4: the first real-world `task` path kind on workflow-scoped PATH_KINDS

**ROUND 4** — consolidated research note (2026-10-09), steps 1–6. Companion to
the round-1 note `research/path-kinds-task-entity-property.md` (whose
sections 1–8 plus the R2.x reviewer record remain the round-1/2 record; see
the pointer added there). All paths below are relative to the ScoutCoder
checkout `/bulk/mvazque2/git/AgentSuite/ScoutCoder`.

Step notes (full detail, cited throughout): `tmp/notes/round4-baseline.md`,
`tmp/notes/round4-step2.md`, `tmp/notes/round4-step3.md`,
`tmp/notes/round4-step4.md`, `tmp/notes/round4-step5.md`.

## R4.1 Scope and headline verdict

Round 4 built the first *real-world* path kind on scout-ai's workflow-scoped
`PATH_KINDS` mechanism, hosted in this ScoutCoder checkout: kind **`task`**
on the probe-host workflow module `TaskKindProbeWF`
(`tmp/path_kinds/round4/task_kind_probe_wf.rb`), with locations `tmp`
(`share/tasks` drafts) and `project` (`lib/<Workflow>/tasks` promoted
copies) — mirroring Scout's real authoring layout.

Verdict: **everything green, no engine defects.**

| area | result | evidence |
|---|---|---|
| registration semantics | INCORPORATION 5/5 | `tmp/path_kinds/round4/out/incorporation_probe.out` |
| CRUD lifecycle | LIFECYCLE 14/14 | `tmp/path_kinds/round4/out/lifecycle_probe.out` |
| quality ops (validate/test/smoke) | QUALITY 11/11 | `tmp/path_kinds/round4/out/quality_probe.out` |
| containment (7 cases × 2 locations) | CONTAINMENT 22/22 (+ rerun 22/22) | `tmp/path_kinds/round4/out/containment_probe.out`, `.../containment_probe_rerun.out` |
| step-2 smokes | REGISTER_SMOKE_OK, HOOK_SMOKE 7/7, PROMOTE_PROBE 5/5 | `.../register_smoke.out`, `.../hook_smoke.out`, `.../promote_probe.out` |

Baseline engine health (step 1, run in the cmp-verified mirror
`tmp/mirror_round4/scout-ai/`): path suite **188 tests / 634 assertions**,
sandbox suite **11 tests / 34 assertions**, probe matrix **101/101** — all
green; outputs recorded in `tmp/notes/round4-out/`. Engine identity pinned:
`lib/scout/llm/agent/path.rb` md5 **`1823c32f57fcc2215a0ebad58a2007b7`**
(verified again at the end of steps 4 and 5). Mid-round drift from the
baseline md5 `d0855b0d…` was **comment-only** — 61 diff lines, **0
non-comment changed lines** (diff recorded at
`tmp/path_kinds/round4/out/engine-drift-since-baseline.diff`).

Findings ledger: **0 engine defects**, 6 documentation gaps, 3 ergonomics
frictions, 3 probe-side lessons (R4.6).

## R4.2 The working PATH_KINDS recipe

Canonical artifact: `tmp/path_kinds/round4/task_kind_probe_wf.rb` (module
`TaskKindProbeWF`, `extend Workflow`, frozen `PATH_KINDS` Hash). Annotated
excerpt of the shape that worked:

```ruby
module TaskKindProbeWF
  extend Workflow
  self.name = 'TaskKindProbeWF'      # resolvable by `tool:` lines

  SCRATCH = File.expand_path('scratch', __dir__).freeze

  PATH_KINDS = {
    'task' => {
      'description' => 'Scout workflow task files (...)',
      'locations' => ['tmp', 'project'],
      'default_location' => 'tmp',
      # roots MUST be absolute (relative roots fail sandbox authorization)
      'roots' => {
        'tmp' => File.join(SCRATCH, 'share', 'tasks'),
        'project' => File.join(SCRATCH, 'lib', 'TaskKindProbeWF', 'tasks')
      },
      # generic CRUD left at engine defaults, restated explicitly;
      # the four non-defaults switched ON:
      'capabilities' => { 'read' => true, 'write' => true, 'edit' => true,
                          'list' => true, 'move' => true, 'rename' => true,
                          'delete' => true,
                          'validate' => true, 'test' => true,
                          'smoke' => true, 'promote' => true },  # patch off
      # 4-arg hooks ->(agent, path, location, args); engine has already
      # resolved + authorized the target for READ before the hook runs
      'validate' => lambda { |agent, path, location, args| ... },
      'test'     => lambda { |agent, path, location, args| ... },
      'smoke'    => lambda { |agent, path, location, args| ... },
      # declarative ONLY (a Callable is rejected by the engine):
      'promotion_destination' => 'project',
      'promotion_post_move' => lambda { |agent, path, location, args| ... }
    }
  }.freeze
end
```

Form choice: the **Hash** form (not Array-of-Hashes) — round-1 precedent and
the shape `register_path_kind` itself takes, so kind names cannot be
silently mis-registered by a missing `"name"` key. The Array normalization
path was deliberately not exercised (R4.8).

Explicit-vs-omitted capability defaults were verified equivalent in step 2
(`tmp/path_kinds/round4/out/register_smoke.out`: the 12 installed tools match
the capability map, with `path_patch` correctly absent).

## R4.3 Conventions established this round

1. **Location-aware paired-test placement + fresh-process execution.**
   `test` writes the generated test to the location-conventional path —
   `tmp` => `share/test/task/<name>.rb`; `project` =>
   `test/<Workflow>/tasks/test_<name>.rb` — then runs it in a FRESH ruby
   process, returning `exit_status` plus full stdout/stderr in the envelope.
   Persisted evidence copies:
   `tmp/path_kinds/round4/out/evidence-test-tmp-hello.rb` (sha256
   `c87615d02369…`, 1060 B), `.../evidence-test-project-test_hello.rb`
   (`df3b272d9448…`, 1088 B), `.../evidence-test-tmp-failing_probe.rb` +
   `.../evidence-failing-test-stdout.txt` (seeded failure, step 4).
2. **Sequencing rule (LiveWorkflow live-loading).** The `tmp` root is
   live-loaded by the scaffold `workflow.rb`; a syntax-broken fixture there
   poisons every later scenario that requires `workflow.rb`. Adversarial
   validate fixtures run LAST and are deleted immediately
   (`tmp/path_kinds/round4/quality_probe.rb`).
3. **Evidence persistence.** Tool hook envelopes carry complete
   fresh-process stdout/stderr — persist them to `out/` as report-grade
   evidence instead of quoting from memory (step 4 added
   `evidence-failing-test-stdout.txt` mid-run for exactly this reason).
4. **Promote semantics.** No-clobber by default with explicit `overwrite`
   opt-in; the ENGINE performs the move to a declaratively-resolved,
   both-endpoints-authorized destination; `promotion_post_move` runs AFTER
   the move with authorized endpoints and relocates the paired test file
   (`tmp/path_kinds/round4/out/lifecycle_probe.out`, promote-refuse /
   promote-overwrite rows).

## R4.4 Engine contract as verified this round

Six contract facts verified against live source (step 1,
`tmp/notes/round4-baseline.md`; line numbers are the LIVE md5
`1823c32f…` values after the comment-only drift — the baseline recorded the
pre-drift ones, ~1 line lower):

1. `integrate_workflow_path_kinds` at `lib/scout/llm/agent/path.rb:92`;
   whole-workflow `tool:` incorporation from `Agent#ask`
   (`lib/scout/llm/agent.rb:139-143`, `next if task_name`); RemoteWorkflow
   rejected in `path_workflow_namespace` (live `:130-135`);
   discovery via `const_defined?(:PATH_KINDS, false)` `path.rb:96`;
   Hash/Array normalization `path.rb:140-174`; deep copy `path.rb:119,176`;
   cross-workflow collision raise `path.rb:106-112`; same-workflow
   re-registration idempotent (same guard).
2. Definition entry shape: description `:219`; locations/default_location
   `:233,239-242`; roots Hash with absolute-path enforcement
   `:1002-1025`; capabilities Hash-or-Array `:220-231`; 4-arg hooks
   (dispatch `:801`, `path_kind_operation` `:1412-1431`);
   `promotion_destination` declarative-only `:1346-1360`; `promotion_post_move`
   after the move (`post_move.call(self, path, location.to_s, hook_args)` at
   `:1400`).
3. `DEFAULT_CAPABILITIES` `path.rb:28-41`: read/write/edit/list/move/rename/
   delete ON; validate/test/promote/smoke/patch OFF.
4. Gated tool installation `install_path_tools` `path.rb:496-509`; validate/
   test tool schemas have NO extension mechanism (the "may extend" comment at
   live `:887` is stale — confirmed against both live and mirror
   `tmp/mirror_round4/scout-ai/lib/scout/llm/agent/path.rb:899`).
5. `path_promote` `path.rb:1325-1418`: capability check, source existence,
   both endpoints authorized, no-clobber default + `overwrite`, engine
   performs the move (`:1390`), post-move hook with authorized endpoints.
6. Tool storage `@other_options[:tools][name] = [callable, tool_definition]`
   via `path_install_tool` `path.rb:694` / `:715` — the programmatic probe
   inspection point.

**Incorporation semantics** (driven through the real `Agent#ask` with the
offline mock endpoint; `tmp/path_kinds/round4/incorporation_probe.rb`):
whole-workflow `tool: TaskKindProbeWF` registers the kind and installs 12
path tools; task-level `tool: TaskKindProbeWF hello` registers nothing.
Cross-workflow conflict message verbatim:

> `Path kind "task" is already provided by workflow "TaskKindProbeWF"; workflow "OtherWF" cannot redefine it. Two workflows must not supply the same path kind.`

Idempotence: re-registration leaves registry/source unchanged, no duplicate
`path_kinds` tool.

**Corroborating unit tests** (names + line numbers re-checked in the MIRROR
`tmp/mirror_round4/scout-ai/test/scout/llm/agent/test_path.rb`; the mirror
numbers are cited):

- `test_whole_workflow_tool_line_registers_kinds_and_installs_tools` **:2886**
- `test_task_level_tool_line_registers_nothing` **:2899**
- `test_workflow_without_path_kinds_is_silent_noop` **:2909**
- `test_conflict_between_two_workflows_raises_naming_both` **:2931**
- `test_same_workflow_repeated_is_idempotent` **:2946**

All green in the baseline suite run (188 tests / 634 assertions).

**Fail-closed cross-location traversal (verified semantics, not a defect):**
authorization uses the CALL location's root only
(`path_authorize!` `path.rb:996-1015`, `LLM::Sandbox.authorize_path`
`lib/scout/llm/sandbox.rb:76-100` with `inside?` boundary-aware containment),
so a traversal path from `tmp` that canonically lands in the `project` root
is denied (`outside_grants`) even though both roots belong to the same kind.
Symlinks are canonicalized by the component-wise realpath walk
(`sandbox.rb:14-67`), so in-grant symlinks to outside files are denied for
both read and write. Evidence:
`tmp/path_kinds/round4/out/containment_probe.out` (cases 3, 4, 5).

## R4.5 Probe results summary

| step | probe | recorded output | verdict |
|---|---|---|---|
| 2 | `tmp/path_kinds/round4/register_smoke.rb` | `out/register_smoke.out` | REGISTER_SMOKE_OK |
| 2 | `tmp/path_kinds/round4/hook_smoke.rb` | `out/hook_smoke.out` | HOOK_SMOKE 7/7 |
| 2 | `tmp/path_kinds/round4/promote_probe.rb` | `out/promote_probe.out` | PROMOTE_PROBE 5/5 |
| 3 | `tmp/path_kinds/round4/incorporation_probe.rb` | `out/incorporation_probe.out` | INCORPORATION 5/5 |
| 3 | `tmp/path_kinds/round4/lifecycle_probe.rb` | `out/lifecycle_probe.out` | LIFECYCLE 14/14 |
| 4 | `tmp/path_kinds/round4/quality_probe.rb` | `out/quality_probe.out` (+ `quality_probe-evidence.txt`, `evidence-*.rb`, `evidence-failing-test-stdout.txt`) | QUALITY 11/11 |
| 5 | `tmp/path_kinds/round4/containment_probe.rb` | `out/containment_probe.out` (+ rerun, `containment_probe-evidence.txt`) | CONTAINMENT 22/22 ×2 |

All `out/` paths above are under `tmp/path_kinds/round4/out/` and were
existence-checked when this note was written.

## R4.6 Findings ledger

**Engine defects: none found this round** (steps 2–5, including 7 hostile
containment cases × 2 locations, all fail-closed).

Documentation gaps (engine comments/docs, all with evidence):

1. **Stale hook-arity example** — `"validate" => ->(path, content) { ... }`
   at live `path.rb:280`; hooks are 4-arg `(agent, path, location, args)`
   (`path.rb:1412-1431`). Step-2 friction finding 4.
2. **Stale "may extend this schema" comment** for validate/test tool
   parameters — live `path.rb:887` (mirror `:899`); no code path consumes a
   kind `"parameters"` extension for validate/test. Baseline fact 4.
3. **Move is same-location relocation only** — `destination` is resolved
   with the SOURCE location (`path.rb:870-874` schema, `:1283-1289`
   `path_relocate`); there is no `destination_location` argument; a
   same-name cross-location move is literally `FileUtils.mv(f, f)`
   `ArgumentError`. Cross-location transfer is promote's job. Step-3
   finding 1.
4. **`path_edit` selector must be a mapping** `{"type" => "lines"|"chars"|
   "regexp", ...}` (`lib/scout/llm/agent/path/edit.rb:58-84`); a bare string
   raises `ParameterException`. Step-3 finding 2.
5. **Tool callables swallow ScoutException into an error envelope**
   (`path.rb:705-710`: a JSON *String* `{"exception":…, "exception_line":…}`),
   while the public `agent.path_*` methods raise. Both behaviors verified
   consistent; worth documenting because it changes how callers assert
   failures. Step-3 finding 3, step-5 envelope parsing.
6. **`Scout.etc` endpoint mounting needs an explicit path-map prepend**
   outside the upstream test helper (`Scout.prepend_path(:etc, ...)`) —
   step-3 friction, probe file
   `tmp/path_kinds/round4/incorporation_probe.rb` + `etc/AI/mock.yaml`.

Ergonomics friction (ours to design around):

1. **Live-loaded tmp root interference** — see R4.3.2 sequencing rule.
2. **Suggested registration-time "root exists" sanity warning** — a
   one-level-off `File.expand_path` join produced silently wrong absolute
   roots in step 2; the engine accepted them (step-2 finding 3).
3. **Hook arity is enforced only at dispatch time**, so a wrong-arity hook
   fails far from authoring (compounds gap 1).

Probe-side lessons:

1. **Write-tool path divergence** — some authored files landed under
   `~/.scout/tmp/...` rather than the checkout; copy back and verify
   (`ls` after every `write`). Steps 2–4.
2. **Plain string literals beat heredocs for fixtures** containing
   deliberately-broken Ruby (heredoc + split gymnastics caused two probe
   syntax errors in step 4).
3. **The ScoutException envelope is a JSON String, not a Hash** — parse
   before asserting on messages (step 5).

## R4.7 Trusted-plugin boundary note

`validate`/`test`/`smoke` hooks are **trusted code executing in the agent
process**. The engine's authorization covers the TASK FILE (resolved and
authorized for read before the hook runs, `path.rb:1412-1431`); everything
the hook then does — notably the `test` hook writing generated test files to
`share/test/task/` and `test/<WF>/tasks/`, i.e. **outside the kind's declared
roots** — runs on trust. This is by design (the engine cannot know a kind's
conventional side paths) but is a real boundary for production hosting: a
malicious or buggy kind definition is arbitrary code with the agent's
authority. Production hosting should treat PATH_KINDS declarations like code
review, not configuration. Evidence of the boundary: the `test` hook in
`tmp/path_kinds/round4/task_kind_probe_wf.rb` writes outside `roots`, and
the containment matrix (step 5) deliberately did NOT try to contain hook
side effects — it contained only engine-mediated path operations.

## R4.8 Out of scope / deferred

- **Array-of-Hashes PATH_KINDS normalization form** not exercised (the Hash
  form was chosen; see R4.2).
- **RemoteWorkflow rejection** not probed — needs a live scout server; the
  ask path skips remote targets silently by design (`agent.rb:~131`).
- **`entity` / `entity_property` kinds** on the workflow-scoped mechanism
  remain future work (round-1 drafts exist under `tmp/path_kinds/`, partially
  obsolete — their custom promote lambdas predate the declarative
  `promotion_destination`).
- Upstream scout-ai doc/comment fixes (R4.6 gaps 1–3) — to be reported, not
  fixed from this session's write grants.

## R4.9 Permanent hosting recommendation

**Recommendation: host the production `task` kind in ScoutCoder itself.**
ScoutCoder's own layout — authoring drafts under `share/tasks/`, promoted
built-ins under `lib/ScoutCoder/tasks/`, paired tests under
`share/test/task/` and `test/ScoutCoder/tasks/` — is exactly the two-location
layout the kind models, so the kind's `roots` map directly onto real
directories that ScoutCoder's `LiveWorkflow` loading already understands.
The probe module's scratch roots are the same relative layout, only anchored
at `tmp/path_kinds/round4/scratch` for isolation. scout-ai cannot host it
from this session's write grants (its tree is read-only except `tmp/`), and
hosting in scout-ai would also couple a ScoutCoder-specific layout
convention to the engine repository. The remaining production work is
mechanical: re-anchor `SCRATCH` to the checkout root, wire PATH_KINDS into
ScoutCoder's `workflow.rb`, and re-run the round-4 probe set against the
real roots. This paragraph is a recommendation, not a decision.
