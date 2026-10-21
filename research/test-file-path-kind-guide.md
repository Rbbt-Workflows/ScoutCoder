# The `test_file` path kind and the `run_test` runner — build guide (round 9)
> **SUPERSEDED IN PART (round 10, 2026-10-17).** This guide reflects the
> round-9 build. Two of its decisions were changed by the round-10
> correction round, whose authoritative statement is the ScoutCoder
> README (`## Agent path kinds` — "Agent path kinds" section) and the
> round-10 research note `research/path-kinds-round10-test-file-corrections.md`:
>
> 1. **`smoke` on `test_file` is GONE** (§3 capability table, §4 smoke
>    verdict). Round 10 removed the smoke capability and handler: the
>    kind offers `validate` (static) + `run_test` (executing, reporting
>    `passed` and exit status separately). The "a failing test still
>    smokes OK" verdict no longer exists.
> 2. **The project-side `entity_property` test layout is HIERARCHICAL, not
>    flattened** (§2 project-side table, §7 pairing table).
>    `entity_property/<entity>/<property>` maps to
>    `test/<workflow>/entity/<entity>/test_<property>.rb`, replacing the
>    `test_<entity>_<property>.rb` flattening, which was not invertible
>    for underscore-bearing names.
>
> Additionally superseded by round 10: the source kinds' paired-test
> RELOCATION hooks (§7) — no kind registers `promotion_post_move` anymore.
> Everything else in this guide is historical context.


Written by the round-9 `test-file-kind-investigation` conversation. Audience: the
build conversation that implements `lib/ScoutCoder/path_kinds/test_file.rb`, the
`run_test` runner, and the ScoutCoder-side cleanup after the engine removes the
built-in `test` path operation. Working checkout:
`/bulk/mvazque2/git/AgentSuite/ScoutCoder` (referred to as `<checkout>`; workflow
name interpolated as `<workflow>` via `ScoutCoder.target_workflow_name`). Engine:
`~/git/scout-ai` (READ-ONLY for this work; `path.rb` md5 `7ac34d05…` @ HEAD
`4680bd9` at baseline — re-pin at build time).

Everything below was settled against the live files listed in the evidence
index. Decisions already endorsed (do not reopen): smoke = initialization-only
for source kinds; test files are resources in ONE kind distinguished by path
convention; the `test` operation stops creating/owning test files; running tests
= `run_test`; association stays a ScoutCoder convention; test_file tmp root =
`share/test/`, project root = the `test/<workflow>/` subtree; test_file smoke =
"the tests actually RAN".

---

## 1. Design summary

One new path kind, `test_file`, owns every unit and integration test file as an
ordinary resource. It is a normal filesystem-backed kind (roots + optional
`resolve`/`list` hooks) whose virtual paths mirror the **tmp-side (share)
spelling**: first path segment is the subject tier (`task`, `entity`,
`entity_property`, `helper`) or the marker `integration`. Unit vs integration is
decided by that first segment (`integration` ⇒ integration, anything else ⇒
unit) — path convention, not a second kind, exactly per the endorsed design.

A custom path operation named `run_test`, registered by the `test_file` kind,
becomes the model-facing runner: the engine installs ONE aggregated tool
`run_test` (engine `install_path_tools` + `path_custom_tool_definition`), with
`kind`/`path` forced required by the engine and a declared `scope`
(`file|directory|suite`) plus optional `timeout_seconds`. A ScoutCoder workflow
task `run_test` wraps the same support module so users get CLI access
(`scout workflow task ScoutCoder run_test …`), mirroring the `run_task_test`
precedent. Both surfaces share one fresh-process runner module with a per-file
timeout and the proven TERM→KILL process-group kill discipline.

The shared paired-test location authority (`ScoutCoder::PathKindTestFiles`,
today in `path_kinds/test_file_paths.rb`) moves INTO
`lib/ScoutCoder/path_kinds/test_file.rb` and is superseded/absorbed there (the
file's own header schedules exactly this). The three source kinds keep
`validate` + `smoke` only; their `test` handlers, `test` capability flags and
the generated-harness templates are deleted when the engine `test` operation is
removed. Their `promotion_post_move` paired-test relocation stays byte-for-byte
(the regression suite pins six tests on it), now calling the authority in its
new home. test_file smoke = "the tests actually RAN": a deliberately failing
test smokes OK; an unparseable/unloadable file smokes FAIL; detection uses the
Test::Unit run-summary output marker, not raw exit status.

## 2. Locations layout (settles open question 1)

### tmp side (`share/test/`, LiveWorkflow drafts' paired tests — never loaded by LiveWorkflow)

| tier | path | class |
|---|---|---|
| task | `share/test/task/<name>.rb` | unit (no `test_` prefix) |
| entity | `share/test/entity/<name>.rb` | unit (no prefix) |
| entity_property | `share/test/entity_property/<entity>/<entity>.<property>.rb` | unit (no prefix, nested) |
| helper | `share/test/helper/<name>.rb` | unit (existing `author_helper_test` convention) |
| integration | `share/test/integration/[<feature>/]<name>.rb` | integration (marker segment) |

### project side (`test/<workflow>/`, mirrors `lib/<workflow>/` per Scout convention)

| tier | path | class |
|---|---|---|
| task | `test/<workflow>/tasks/test_<name>.rb` | unit (`test_` prefix) |
| entity | `test/<workflow>/entity/test_<name>.rb` | unit |
| entity_property | `test/<workflow>/entity/test_<entity>_<property>.rb` | unit (flattened) |
| integration | `test/<workflow>/integration/test_<name>.rb` | integration |

Rules: the share side carries **no** `test_` prefix; the project side always
does; the property test name flattens the nested virtual path
(`<entity>/<property>.rb` → `test_<entity>_<property>.rb`). These are exactly
the spellings ratified in the round-9 disposition (three-way agreement between
README table, helper code and suite seeds) and consumed TODAY by
`TaskTestSupport.test_source_path` (`lib/ScoutCoder/task_test_support.rb:43-56`)
— changing them would break `run_task_test`.

**Unit/integration convention:** first path segment `integration` ⇒ integration
test; any other first segment (`task`, `entity`, `entity_property`, `helper`) ⇒
unit test. Nothing else distinguishes them; both classes are ordinary resources
in the same kind with identical capabilities.

Justification against current conventions: (a) zero churn to the just-ratified
paired-test spellings on both sides; (b) the project side keeps mirroring
`lib/<workflow>/` (Scout repo convention: `test/ScoutCoder/…` mirrors
`lib/ScoutCoder/…`, see README §Layout conventions and every
`test/ScoutCoder/**` file's line-1 helper require); (c) integration tests pair
with no single source file, so a dedicated `integration/` branch under the same
project root (rather than interleaving) is the honest representation and keeps
suite discovery a single recursive glob per root.

### Kind declaration shape

```ruby
PATH_KIND_TEST_FILE_DEFINITION = {
  'description' => "Unit and integration test files for #{target_workflow_name} (drafts in share/test, promoted copies in test/#{target_workflow_name})",
  'extension' => 'rb',
  'locations' => ['tmp', 'project'],
  'default_location' => 'tmp',
  'roots' => {
    'tmp' => Scout.share.test,                          # unlocated Scout path, pinned absolute at registration
    'project' => Scout.root.test[target_workflow_name]  # ditto; use .find(:current) ONLY inside hooks, never bare .find
  },
  'sandbox' => true,
  'capabilities' => {
    'read' => true, 'write' => true, 'edit' => true, 'list' => true,
    'move' => true, 'rename' => true, 'delete' => true,
    'validate' => true, 'smoke' => true, 'promote' => true
    # 'patch' => false (default), 'test' => false (default; operation being removed)
  },
  'resolve' => ...,   # see below
  'list'    => ...,   # see below
  'validate' => ...,
  'smoke'   => ...,
  'promotion_destination' => 'project',
  'operations' => { 'run_test' => {...} }
}
```

Follow the round-8 contract everywhere: roots declared as relative Scout paths
(engine `path_pin_roots!` pins them absolute at registration against
`:current`); never `File.expand_path` another repo's layout; inside hooks always
anchor with `.find(:current)` — bare `.find` on `Scout.lib[...]` /
`Scout.root[...]` resolves to the **user store** (`~/.scout/...`) from any
foreign checkout (verified trap, round-8 note).

### The `resolve` hook (location-dependent file names)

The two sides name the same logical test differently (`<name>.rb` vs
`test_<name>.rb`, `task/` vs `tasks/`, nested vs flattened property names), so
plain root-joining cannot express the mapping. Use the engine's custom
`resolve` hook (`path.rb` validates it callable at registration; `resolve_path`
prefers it):

- virtual path = the tmp-side spelling without the `share/test` root and
  without the `.rb` extension, e.g. `task/greet_user`,
  `entity/demo_widget`, `entity_property/demo_widget/tag_palette`,
  `helper/join_parts`, `integration/round_trip`.
- `resolve(agent, path, location)`:
  - `tmp` → `Scout.share.test[<segments joined>].set_extension('rb').find(:current)` (or the authority's `path_kind_*_test_file` helpers, extended with `helper/` and `integration/` tiers).
  - `project` → the paired project spelling via the SAME authority functions that the source kinds' `promotion_post_move` hooks use today (`path_kind_test_file(name,'project')`, `path_kind_entity_test_file`, `path_kind_entity_property_test_file`; add `helper` and `integration` project spellings — helper project side is NOT ratified, see §7).
- The hook must return an object whose `to_s` is the absolute path (a Scout
  `Path` is fine; the FS boundary uses `target.to_s`). Handle the extension
  itself — the engine skips its default `set_extension` when a `resolve` hook
  exists.
- Directories for `run_test` directory/suite scopes: resolving a path with no
  file extension semantics that names a tier directory (e.g. `task`, `integration`,
  or `.`) should return the corresponding directory under the location root, so
  `path_dispatch` can authorize it `:read` before the handler runs.

Why `resolve` instead of re-shaping conventions: it preserves every ratified
on-disk spelling (including `run_task_test`'s live dependencies), keeps ONE
kind, and makes `path_promote` do the right thing with **no** `promotion_post_move`
hook on test_file itself — the engine resolves the same virtual path at the
`project` location, which the hook maps to the `test_`-prefixed spelling, and
the engine performs the move (`path_promote` resolves the declarative
destination, authorizes both endpoints, checks no-clobber, moves itself).

### The `list` hook

Provide a `list` hook so `path_list` round-trips with `path_read`/`run_test`:
map real files under the location root back to virtual spellings (project side:
strip the `test_` prefix, `tasks/`→`task/`, un-flatten
`test_<entity>_<property>.rb` → `entity_property/<entity>/<entity>.<property>…`).
Without it, `path_list` (which globs the pinned root) would return project-side
file names that do not round-trip through the virtual-path space.

## 3. Capabilities and operations (settles open question 2)

| operation | on | notes |
|---|---|---|
| read / write / edit / list / move / rename / delete | yes | ordinary file view over the two roots (engine defaults) |
| validate | yes | static only, never executes (below) |
| smoke | yes | fresh-process run; verdict = "ran" (§4) |
| promote | yes | tmp → project via `promotion_destination: 'project'` + the `resolve` hook; no `promotion_post_move` on this kind (a test has no paired test) |
| patch | **no** | whole-file authored sources, same as the three source kinds; engine default-off |
| test | **no** | the operation is being removed; nothing named `test` may be registered (see §5) |
| **custom: `run_test`** | registered | the runner (§5); registering a custom op establishes support implicitly, no capability flag |

### validate

Pure static checks on one file (mirror the source kinds' shape):
1. target exists and is a file (else `ok:false` with reason).
2. Ruby syntax: in-process `RubyVM::AbstractSyntaxTree.parse` (precedent: all
   three kinds' validate; chosen over `ruby -c` — same parser, no spawn, no side
   effects). Syntax error ⇒ error.
3. Test shape (Test::Unit is this repo's framework — `test/test_helper.rb`
   requires `test/unit`; every `test/**/*.rb` uses the line-1 helper require):
   - **error** if the source neither requires the test harness
     (`require 'test/unit'` or the `test_helper` idiom) nor declares a
     `< Test::Unit::TestCase` subclass — the file cannot run as a test at all;
   - **warning** if exactly one of the two is present (loads the framework but
     declares no case, or declares a case without loading the framework);
   - **warning** if no `def test_` method is declared anywhere;
   - **warning** (project location only) if the file name lacks the `test_`
     prefix, and (tmp location only) if it carries one — cheap convention
     checks that catch tier mistakes.
4. Location-class consistency: **warning** when the first virtual path segment
   disagrees with the file's declared nature — unenforceable statically, so do
   NOT try; the `integration` marker is purely by path.

Return shape: `{'ok'=>…, 'kind'=>'test_file', 'op'=>'validate', 'path'=>…,
'location'=>…, 'class'=>'unit'|'integration', 'reasons'=>[…], 'warnings'=>[…]}`
(same envelope as the existing kinds).

### smoke

Fresh process, bounded time, runs the file exactly the way `run_task_test`
does; verdict per §4. Never writes anything. Details in §4.

## 4. Smoke semantics and exit-class taxonomy (settles open question 4)

### Exit classes

Running one test file in a fresh child (`RbConfig.ruby -I <checkout>/lib -e
LOADER <file>`, `chdir:` the checkout root, loader =
`$LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd)); require "./workflow";
load ARGV.fetch(0)`) produces exactly four observable classes:

| class | meaning | detection |
|---|---|---|
| `clean_pass` | framework ran, all assertions passed | exit status 0 **and** run-summary line present |
| `assertion_failure` | framework ran, ≥1 failure or error INSIDE tests | exit status non-zero **and** output contains a Test::Unit run-summary line matching `/\d+ tests?, \d+ assertions?(?:, \d+ failures?(?:, \d+ errors?)?)?/i` (test-unit prints e.g. `14 tests, 76 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications`) |
| `load_error` | the file never ran as a test: Ruby `SyntaxError`, `LoadError`, `NameError` or any raise during `load` | exit status non-zero **and** NO run-summary line (a Ruby backtrace instead; the framework never started or aborted before its summary) |
| `timeout` | runner killed the process group before completion | runner's own `timed_out` flag (TERM→KILL on the process group, per `TaskTestSupport.run_test`); `ran` is unknown, treated as not-ran |

Exit status alone CANNOT distinguish `assertion_failure` from `load_error`
(both non-zero) — the summary-line marker is the discriminator. That is why the
verdict rule is marker-based.

### Verdict rule

**smoke OK ⟺ the child produced a Test::Unit run-summary line AND that summary
reports at least one test ran** (`tests > 0`), or the process exited 0 with a
summary. In terms of classes: `clean_pass` and `assertion_failure` ⇒ smoke OK;
`load_error` and `timeout` ⇒ smoke FAIL.

Consequences (all deliberate):
- a **deliberately failing test smokes OK** — it demonstrably ran
  (`ran: true, passed: false, exit_class: 'assertion_failure'` recorded in the
  result);
- an **unparseable or unloadable file smokes FAIL** (`exit_class: 'load_error'`);
- a **timeout smokes FAIL** (`exit_class: 'timeout'`, `ran: 'unknown'`);
- a file whose summary reports **0 tests** smokes FAIL with reason
  `no tests discovered` — "the tests actually RAN" is falsified when zero tests
  ran. (Judgment call: a shared abstract base file would trip this; flagged in
  §10 for the build conversation to flip if it proves annoying — the simpler
  alternative is dropping the `tests > 0` conjunct.)

Result envelope (success): `{'ok'=>true, 'kind'=>'test_file', 'op'=>'smoke',
'path'=>…, 'location'=>…, 'ran'=>true, 'passed'=>bool, 'exit_class'=>…,
'exit_status'=>int, 'tests'=>int, 'summary'=><summary line>, 'stdout'=>…,
'stderr'=>…}`. Failure: raise `ParameterException`
`"smoke: test_file '<path>' failed at stage=run: <exit_class>: <first line>"`
(matching the round-9 source-kind smoke envelope: every failure is a
`ParameterException` carrying the stage). A missing/non-file target fails at
`stage=check` before any process spawn (precedent: task/entity/property smoke).

Timeout: **hardcode `SMOKE_TIMEOUT = 120`** in the module (the model-facing
`path_smoke` tool carries only kind/path/location, so no argument channel
exists; unbounded smoke would wedge the agent loop — the existing kind smoke
hooks' lack of a timeout is a known wart, do not copy it). Use the
`TaskTestSupport.run_test` kill discipline: `Open3.popen3(..., pgroup: true)`,
deadline on `Process.clock_gettime(CLOCK_MONOTONIC)`, `TERM` then `KILL` on
`-wait_thread.pid`, so child subprocesses spawned by the test die too.

Trust boundary (document in code, mirroring the existing hooks): smoke loads
agent-authored Ruby in a fresh child with no OS sandbox; the parent only parses
stdout/stderr. Process isolation, not confinement — same statement the three
source kinds carry.

## 5. The `run_test` surface (settles open question 3)

**Recommendation: both surfaces, one shared support module, with the custom
path operation as the primary model-facing surface.**

### Primary: custom path operation `run_test` on the `test_file` kind

Engine mechanics (verified in `path.rb`): registering under `"operations"`
establishes support implicitly (no capability flag); `install_path_tools`
installs **one aggregated tool named exactly `run_test`** across all kinds that
declare it (`path_custom_tool_definition`; exact parameter-contract match
required if a second kind ever declares it); the tool's callable routes through
the central `path_dispatch`, which resolves the target, authorizes it with the
declared mode BEFORE any callback, then calls a `:full` handler
`implementation.call(self, target, args)` (trusted plugin code). The engine
forces `kind` and `path` into the required list and forbids custom parameters
named `kind`/`path`/`location`.

```ruby
'operations' => {
  'run_test' => {
    'description' => 'Run test files: one file, every file under a path prefix, or the entire suite, each in a fresh Ruby process.',
    'parameters' => {
      'properties' => {
        'scope' => {'type' => 'string', 'enum' => %w[file directory suite], 'default' => 'file',
                    'description' => 'file: run the single test file at path. directory: run every test file under the path prefix. suite: run every discovered test file in both locations (path is the root selector; use ".").'},
        'timeout_seconds' => {'type' => 'integer', 'default' => 120,
                              'description' => 'Per-file timeout in seconds.'}
      },
      'required' => %w[scope]
    },
    'implementation' => ->(agent, target, args) { ScoutCoder::TestFileSupport.run(agent, target, args) },
    'authorization' => :read,   # the target is a file/dir we read; execution is trusted-plugin territory, like smoke
    'type' => :full
  }
}
```

- `path` is always required (engine forces it); it is the **selector**: a
  virtual test path for `scope=file`, a tier prefix (`task`, `integration`,
  `.`) for `scope=directory`, and `.` (or any root-level selector) for
  `scope=suite`.
- **Never name an operation `test`**: it collides with the built-in while that
  exists (`path_normalize_custom_operations` raises on built-in collision) and,
  after removal, would resurrect the create-or-execute blur the design
  rejected. `run_test` collides with nothing.

### Secondary: ScoutCoder workflow task `run_test`

A new task file `lib/ScoutCoder/tasks/test_runner_tools.rb` (patterned on
`tasks/task_test_tools.rb`), wrapping the same
`ScoutCoder::TestFileSupport`:

```ruby
input :path, :string, 'Test file path (absolute or checkout-relative), directory prefix, or "." for the suite'
input :scope, :select, 'Run one file, a directory, or the whole suite', 'file', select_options: %w[file directory suite]
input :location, :select, 'Which side to run', 'tmp', select_options: %w[tmp project both]
input :timeout_seconds, :integer, 'Per-file timeout in seconds', 120
task :run_test => :json do |path, scope, location, timeout_seconds| ... end
export_exec :run_test
```

Justification for both: the custom op gives the model a first-class,
engine-authorized, auto-installed tool with zero extra plumbing (the engine
aggregates, documents and routes it); the task gives users/CI the CLI surface
(`scout workflow task ScoutCoder run_test --path . --scope suite`) that
`run_task_test` established as the repo's user-facing test runner idiom
(README `## Testing` + `# Tasks` entries; the sole user doc). Keeping
`run_task_test` untouched preserves its paired-task semantics; `run_test` is
the general runner over the new kind. One support module prevents drift
between the surfaces.

### Shared support module

`lib/ScoutCoder/test_file_support.rb`, module
`ScoutCoder::TestFileSupport`, modeled on `TaskTestSupport` (constant
`DEFAULT_TIMEOUT = 120`; `project_root` anchor; safe-child-path guard):
- `discover(location, prefix)` → sorted list of absolute test files: tmp root
  `share/test/**/*.rb`; project root `test/<workflow>/**/*.rb` filtered to
  `test_*.rb` (the project side's prefix convention); excludes non-`.rb`.
- `run_file(path, timeout_seconds:)` → one fresh-process run (loader above,
  `chdir:` checkout root, `pgroup: true`, TERM→KILL), returning the exit-class
  classification of §4 (`ran`, `passed`, `exit_class`, `exit_status`,
  `summary`, `stdout`, `stderr`, `timed_out`).
- `run(scope:, location:, prefix:, timeout_seconds:)` → per-file results array
  + aggregate (`ran_count`, `passed_count`, `failed_count`, `not_run_count`,
  `overall_passed`). **Empty discovery is an error** (`ParameterException`
  "no test files found for scope/prefix") — never a vacuous pass. Files run
  sequentially, each with its own timeout, results accumulated incrementally
  so a late hang does not lose earlier output.
- Directory/suite scopes run BOTH sides by default in the task (`location:
  'both'`); the path-op handler defaults to the tool's `location` argument and
  treats `scope=suite` as both locations regardless (the suite is the whole
  kind), with the per-location runs labeled in the result.

## 6. Timeout policy per scope (settles open question 8)

| scope | default per-file timeout | rationale |
|---|---|---|
| file | 120 s | the `run_task_test` / `run_helper_test` precedent (`TaskTestSupport::DEFAULT_TIMEOUT = 120`, `HelperTestSupport::DEFAULT_TIMEOUT = 120`); a single test that cannot finish in 120 s is hung in practice |
| directory | 120 s per file | each file is independently budgeted and independently killed; an aggregate cap would let one slow file starve the rest |
| suite | 300 s per file | suite scope includes the heavyweight files: this checkout's own tests spawn fresh Ruby subprocesses per test (`test/ScoutCoder/test_path_kinds.rb` builds `LLM::Agent`s, registers kinds and runs `Open3` children; `test_entity_tools.rb` similar), so a single file legitimately exceeds 120 s; 300 s covers the slowest observed patterns with margin while keeping a hang bounded. Worst-case wall clock is `300 s × N files`, but timeouts are per-file, so partial results survive |

`timeout_seconds` remains an override on both surfaces. Rationale for per-file
(rather than aggregate) budgeting everywhere: the kill discipline is
process-group-scoped, so it can only ever be per-child; and per-file budgets
make one hung test a single red row instead of a lost suite run.

## 7. Association convention and relocation plan (settles open questions 5 and 6)

### Association = pure ScoutCoder convention, owned by ONE module

No engine knowledge. The paired-test derivation (unchanged rules, single home):

| source (tmp draft) | paired test tmp | paired test project |
|---|---|---|
| `share/tasks/<name>.rb` | `share/test/task/<name>.rb` | `test/<workflow>/tasks/test_<name>.rb` |
| `share/entities/<name>.rb` | `share/test/entity/<name>.rb` | `test/<workflow>/entity/test_<name>.rb` |
| `share/entity_properties/<entity>/<property>.rb` | `share/test/entity_property/<entity>/<entity>.<property>.rb` | `test/<workflow>/entity/test_<entity>_<property>.rb` |
| `share/helpers/<name>.rb` | `share/test/helper/<name>.rb` | **not ratified** — recommend `test/<workflow>/helpers/test_<name>.rb` by symmetry, flagged in README as awaiting ratification (helpers have no promotion story today) |
| (none — integration) | `share/test/integration/<name>.rb` | `test/<workflow>/integration/test_<name>.rb` |

**"The suite" for `run_test scope=suite` = discovery over the two kind roots**
(`share/test/**/*.rb` ∪ `test/<workflow>/test_*.rb` recursive) — explicit
root-based discovery, never a hardcoded literal path, and no engine
involvement.

### Relocation home after the engine `test` removal

1. **Supersede `PathKindTestFiles`**: move the whole module from
   `lib/ScoutCoder/path_kinds/test_file_paths.rb` into
   `lib/ScoutCoder/path_kinds/test_file.rb` (keep the module name
   `ScoutCoder::PathKindTestFiles` for call-site stability; the aggregator's
   `extend` + public-alias pass keeps `ScoutCoder.path_kind_*` receivers
   working). The current file's header mandates exactly this ("ADOPT or
   SUPERSEDE this module rather than fork a fourth copy"; "do not grow new
   test-path logic here"). Delete `test_file_paths.rb`; the aggregator's
   require order becomes `support → test_file → task → entity → entity_property`
   (test_file must load before the kind files that call its helpers).
2. **Extend the authority** with the two new tiers (`helper` project spelling;
   `integration` both sides) and, optionally, the inverse mapping used by the
   `list` hook.
3. **Delete the templates** (`path_kind_test_template`,
   `path_kind_entity_test_template`, `path_kind_entity_property_test_template`):
   with the `test` operation gone, nothing generates tests implicitly —
   "test-file creation becomes an ordinary `test_file` write". The harness
   shape moves to the README (sole user doc) as a copy-paste example.
   Git history preserves the generators.
4. **Keep `promotion_post_move` relocation behavior byte-for-byte** on the
   three source kinds (skip-with-reason when the destination exists without
   `overwrite`; `mkdir_p` + `mv` when moving; no-op creating nothing when no
   tmp paired test exists; result keys `post_move`/`reason`/`test_file_moved`).
   Six regression tests pin this. The hooks now call the authority in its new
   home; they keep writing outside the kind roots — the documented
   trusted-plugin trust boundary, unchanged.
5. **Source kinds reference, never own**: after removing their `test` handlers,
   `test` capability flags and (with them) any test-writing code, the only
   test-location knowledge left in `task.rb`/`entity.rb`/`entity_property.rb`
   is the `promotion_post_move` call into the shared authority — reference
   without ownership, exactly the endorsed split.
6. **`TaskTestSupport` delegates**: `TaskTestSupport.test_source_path` (and
   `write_test`) should delegate to the authority (or at minimum be re-pointed
   at it) so `run_task_test` and the kind cannot drift; `run_test` in
   `task_test_tools.rb` stays as-is (paired-task semantics, unchanged API).

## 8. Regression test plan (settles open question 7)

Baseline today: `test/ScoutCoder/test_path_kinds.rb` — 14 tests / 76
assertions, 0 failures 0 errors. Run with
`ruby -Itest test/ScoutCoder/test_path_kinds.rb` (NOT `scout test` — the CLI
dispatch collides with the `./test` directory; round-8 note).

Keep unchanged (they must stay green through the whole build):
the six `promotion_post_move` hook tests (`test_entity_hook_moves_paired_test_and_nothing_else`,
`test_property_hook_moves_paired_test_and_nothing_else`,
`test_hook_creates_missing_destination_directories`,
`test_hook_is_noop_without_paired_test_and_creates_no_directories`,
`test_hook_skips_with_reason_when_destination_exists_without_overwrite`,
`test_hook_overwrite_true_relocates_over_existing_destination`,
`test_property_hook_direct_invocation_moves_exactly_one_file`,
`test_engine_authorized_set_excludes_paired_test_destination`), the three
round-9 smoke-contract tests, and the two loader-ordering tests.

Add — a new round-9 `test_file` block in `test/ScoutCoder/test_path_kinds.rb`
(reuse `sandbox_kind!`/`confine_kind_root_to_sandbox!`/`snapshot_tree`/
`REAL_ROOTS` machinery; add a `test_file` entry to `KIND_TMP_SUBDIR` handling
since its tmp root is `share/test` itself):

1. `test_test_file_kind_registers_expected_capabilities_and_locations` —
   capabilities read/write/edit/list/move/rename/delete/validate/smoke/promote
   true, patch/test false; locations `[tmp, project]`; `operations` registers
   `run_test` (so the aggregated tool installs).
2. `test_test_file_resolve_maps_both_sides` — virtual `task/<n>` →
   `share/test/task/<n>.rb` (tmp) and `test/<wf>/tasks/test_<n>.rb` (project);
   entity tier; property tier flattening (`entity_property/e/p` →
   `share/test/entity_property/e/e.p.rb` / `test/<wf>/entity/test_e_p.rb`);
   `integration/<n>` both sides.
3. `test_test_file_list_round_trips_virtual_paths` — project listing returns
   virtual spellings (prefix stripped, `tasks/`→`task/`, un-flattened).
4. `test_test_file_validate_static_only` — syntax error ⇒ `ok:false`; valid
   Test::Unit file ⇒ `ok:true`; file with neither harness require nor TestCase
   subclass ⇒ error; harness-without-case ⇒ warning; wrong prefix per location
   ⇒ warning. (Static: no child process may spawn — assert via a fixture whose
   body would write a marker file if executed.)
5. `test_test_file_smoke_ok_on_passing_test` — `ok:true, ran:true, passed:true,
   exit_class:'clean_pass'`.
6. **`test_test_file_smoke_ok_on_deliberately_failing_test`** (the required
   case) — body `require 'test/unit'; class X < Test::Unit::TestCase; def
   test_fails; assert_equal 1, 2; end; end`; assert `ok:true`, `ran:true`,
   `passed:false`, `exit_class:'assertion_failure'`.
7. `test_test_file_smoke_fails_on_syntax_error` — `exit_class:'load_error'`,
   ParameterException naming stage=run.
8. `test_test_file_smoke_fails_on_unloadable_file` — `require 'no_such_library_xyz'`
   at top; `exit_class:'load_error'`.
9. `test_test_file_smoke_fails_when_zero_tests_run` — valid harness, no test
   methods; summary shows 0 tests ⇒ `ok:false`, reason `no tests discovered`.
10. `test_test_file_smoke_timeout_fails` — `sleep 30` body, 1 s timeout
    (expose a constant or inject the timeout in the test); `exit_class:'timeout'`.
11. `test_run_test_file_scope_pass_and_fail` — via the aggregated tool
    (`@agent.other_options[:tools]['run_test']`): pass + fail directions, exit
    classes, stdout captured.
12. `test_run_test_directory_scope_aggregates` — two files under a tier prefix;
    per-file results + counts; one failing file ⇒ `overall_passed:false` but
    both files reported.
13. `test_run_test_suite_scope_discovers_both_sides_and_empty_is_error` —
    seeds under both roots; empty sandbox ⇒ ParameterException "no test files
    found".
14. `test_test_file_promote_rewrites_spelling_via_resolve` — promote virtual
    `task/<n>`: `share/test/task/<n>.rb` → `test/<wf>/tasks/test_<n>.rb`; engine
    move (not a hook); overwrite refusal leaves source intact.
15. `test_source_kinds_drop_test_operation_but_keep_relocation` — after the
    engine removal lands: `path_kind_capable?('task','test')` false, no `'test'`
    key in the definitions, and the six relocation tests above still pass
    (already covered; this test asserts the capability surface explicitly).
16. Trust/residue: extend the `REAL_ROOTS` snapshot list with `share/test` and
    `test/ScoutCoder` so every new test proves it wrote nothing in the real
    tree (existing teardown assertion covers this automatically).

Also add `test/ScoutCoder/tasks/test_test_runner_tools.rb` for the `run_test`
**task** (mirroring `test_task_test_tools.rb`): authoring-free — seed a fixture
test file, run each scope, assert the result envelope and that the task refuses
an empty discovery.

And re-run the round-9 scratch-workflow probe
(`tmp/path_kinds/round9/refactor/scratchwf/`, workflow `ScratchProbe`) after
the build: whole-workflow incorporation must register all four kinds and no
resolved path may contain a foreign workflow name.

## 9. Resolved-decisions table

| # | question | decision |
|---|---|---|
| 1 | unit vs integration sub-layout | Existing per-subject tiers (`task/`, `entity/`, `entity_property/`, `helper/`) = unit, unchanged spellings both sides; new `integration/` first-segment marker on both sides (`share/test/integration/…`, `test/<workflow>/integration/test_*.rb`). One kind; distinction is the first path segment. |
| 2 | capabilities/operations | read/write/edit/list/move/rename/delete + validate (static: syntax + Test::Unit shape) + smoke (ran-verdict) + promote (via resolve hook; no post_move); patch off; test off; one custom op `run_test`. |
| 3 | run_test surface | BOTH, one support module: custom path operation `run_test` (primary model-facing; engine auto-installs one aggregated tool) + ScoutCoder task `run_test` (CLI/user). Nothing may be named `test`. |
| 4 | smoke taxonomy / verdict | Classes `clean_pass` / `assertion_failure` / `load_error` / `timeout`, discriminated by the Test::Unit run-summary marker (+ exit status, runner timeout flag). Smoke OK ⟺ summary present AND tests > 0. Failing test ⇒ OK; unloadable/unparseable/timeout/zero-tests ⇒ FAIL. |
| 5 | relocation home | `PathKindTestFiles` superseded into `path_kinds/test_file.rb` (module name kept; `test_file_paths.rb` deleted; load order support → test_file → task → entity → entity_property). `promotion_post_move` behavior kept byte-for-byte on source kinds, calling the authority. Templates deleted; harness example moves to README. Source kinds lose `test` handlers/capability and keep only validate+smoke. |
| 6 | association / suite discovery | Pure convention in the one authority module (table in §7; helper project side flagged unratified). Suite = recursive discovery over the two kind roots (`share/test/**/*.rb` ∪ `test/<workflow>/test_*.rb`); empty discovery is an error. |
| 7 | regression plan | Keep all 14 existing tests green; add 16 kind/runner tests in `test_path_kinds.rb` (incl. the failing-test-smokes-OK case) + a `test_test_runner_tools.rb` for the task; re-run the scratch-workflow incorporation probe. |
| 8 | timeouts | file 120 s, directory 120 s/file, suite 300 s/file (per-file budgets, TERM→KILL on the process group; heavy files spawn fresh subprocesses); `timeout_seconds` override on both surfaces; smoke hardcoded 120 s. |

## 10. Risks and open flags for the build conversation

- **Engine drift is live**: `path_authorize!` resolves a kind root but does NOT
  pass it to `Sandbox.authorize_path` (effective grant is `Dir.pwd`) at engine
  HEAD `4680bd9` (round-9 baseline "honest scope note"). All test_file
  handlers/tests must assume CWD-bounded authorization; the sandbox-confine
  test idiom (`confine_cwd_to_sandbox!`) exists for exactly this.
- **Engine is read-only**; the `test`-operation removal is a separate
  workstream touching it. ScoutCoder must drop the `test` capability/handlers
  in the same change window or briefly carry dead hooks (harmless but noisy).
  The engine's own `test/scout/llm/agent/test_path.rb` and
  `tmp/probe_matrix/probe_01_generic.rb` (L16/L18/L69 reference the `test` op)
  need parallel updates there, not here.
- **The `resolve` hook is load-bearing**: with it, the engine skips root
  joining and extension handling, so the hook owns both; every operation
  (read/write/edit/move/rename/delete/promote/run_test) flows through it. Test
  it first and hardest. Targets must stay under the location root or
  authorization fails.
- **`path` is forced required** on any custom-op tool (engine
  `path_custom_tool_definition`); `scope=suite` therefore uses `path: "."` —
  document this in the tool description so the model does not guess.
- **Zero-tests smoke rule** (§4) is a judgment call; flip to summary-present
  alone if abstract-base test files show up.
- **Helper project-side spelling** (`test/<workflow>/helpers/…`) is invented
  here by symmetry and unratified — flag in README like the round-8/9 notes
  flagged the entity spellings before ratification.
- **ScoutCoder has no git anchor** (broken `.git` gitfile; round-9 baseline) —
  md5 pins before/after every edit; take a pre-edit snapshot of
  `lib/ScoutCoder/path_kinds*` like the round-9 refactor did.
- **Suite runtime**: fresh process per file × full tree is minutes-scale; keep
  results incremental and consider capping concurrent… no — sequential only
  (process-group kills and Scout job caches assume serial runs).

## 11. Evidence index (file:line, all read this round)

ScoutCoder checkout (`/bulk/mvazque2/git/AgentSuite/ScoutCoder`):
- `lib/ScoutCoder/path_kinds/test_file_paths.rb` — 1-25 (header: authority
  moves to `test_file.rb`, adopt/supersede, don't fork), 29 (`path_kind_task_name_in`),
  39-52 (`path_kind_test_file`: tmp `Scout.share.test.task[<name>.rb].find(:current)`,
  project `Scout.root.test[<wf>].tasks["test_<name>.rb"].find(:current)`), 55-92
  (task test template), 94-111 (module-name/top-level-module helpers), 114-126
  (entity test file), 128-152 (entity template), 155-166 (property test file,
  tmp `share/test/entity_property/<e>/<e>.<p>.rb`, project flattened
  `test_<e>_<p>.rb`), 168-199 (property template).
- `lib/ScoutCoder/path_kinds.rb` (aggregator) — header (five-file structure,
  load order, `PATH_KINDS` merge `{task, entity, entity_property}`, re-alias
  pass over `PathKindTestFiles`).
- `lib/ScoutCoder/path_kinds/support.rb` — 26-40 (`target_workflow` memoized,
  CWD-independent per round-9 fix), 44 (`PATH_KIND_ROOT` structural anchor).
- `lib/ScoutCoder/path_kinds/task.rb` — 27-31 (roots `Scout.share.tasks` /
  `Scout.lib[<wf>].tasks`), 34-42 (capabilities incl. `'test' => true`),
  44-95 (validate: AST parse, module wrapper, task declaration, desc warning),
  96-160 (`test` handler: paired write generated/existing/supplied,
  `Open3.capture3` loader, **no timeout**, `test_source` only via direct
  dispatch), ~161-280 (`smoke`: fresh process, `SMOKE_OK`/`SMOKE_FAIL` markers,
  ParameterException w/ stage), 315-341 (`promotion_post_move` relocation:
  skip-with-reason / mkdir_p+mv / `test_file_moved`).
- `lib/ScoutCoder/path_kinds/entity.rb` — 27-31 (roots), 34-42 (capabilities),
  105-160 (`test` handler, same loader), 168-232 (`smoke`: module defined +
  `Entity::MODULES`, no dispatch), 183 (`promotion_destination`), 185-207
  (`promotion_post_move`).
- `lib/ScoutCoder/path_kinds/entity_property.rb` — 27-31 (roots), 34-42
  (capabilities), 44-100 (validate: nested path, module match, no extend,
  property decl), 102-150 (`test` handler), 152-220 (`smoke`: registration +
  `instance_method` UnboundMethod resolution, never dispatched), 225-252
  (promotion + post_move with flattened spelling).
- `lib/ScoutCoder/task_test_support.rb` — 9-10 (`TASK_NAME`, `DEFAULT_TIMEOUT
  = 120`), 18-21 (`project_root`), 22-33 (`safe_child_path`), 34-42
  (`task_source_path`), 43-56 (`test_source_path`: share no-prefix / lib
  `test_<file>.rb` w/ nested dirs), 57-69 (`lib_task_source_path` declaration
  grep), 72-89 (`write_test`: `RubyVM::InstructionSequence.compile`, EXCL
  create, refuses overwrite), 91-136 (`run_test`: fresh process `-I lib` +
  loader string, `chdir root`, `pgroup: true`, TERM→KILL deadline, result
  keys `status/passed/timed_out/stdout/stderr/fresh_process/workflow_loaded/cache_policy`).
- `lib/ScoutCoder/tasks/task_test_tools.rb` — 1-27 (`author_task_test` /
  `run_task_test` tasks, `timeout_seconds` input, `export_exec`).
- `lib/ScoutCoder/tasks/helper_tools.rb` — 19-27 (`run_helper_test` task
  wrapping `HelperTestSupport`).
- `lib/ScoutCoder/helper_test_support.rb` — 8 (`DEFAULT_TIMEOUT = 120`), 91
  (`run_test`).
- `test/test_helper.rb` — 1-7 (`require 'test/unit'`, `$LOAD_PATH` lib+test,
  `require '../workflow'`).
- `test/ScoutCoder/**` — line-1 idiom
  `require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')`
  (grep across the tree); `test/ScoutCoder/tasks/test_*.rb` naming;
  `test/ScoutCoder/test_path_kinds.rb` / `test_LiveWorkflow.rb` at workflow level.
- `test/ScoutCoder/test_path_kinds.rb` — 1-45 (design-decision header),
  52-140 (`setup`/`teardown`, `REAL_ROOTS`, `confine_kind_root_to_sandbox!`,
  `confine_cwd_to_sandbox!`, `swap_kind_root!`, `sandbox_kind!` with
  `Path.setup` roots + `project_root` override), 223-471 (six relocation/trust
  tests incl. hookless control arm), 473-581 (round-9 smoke contracts), 585-655
  (loader-ordering tests).
- `README.md` — §Layout conventions (`test/` mirrors `lib/`, `share/test/…`
  paired tests "run in fresh processes… never loaded by LiveWorkflow"), §Agent
  path kinds (kinds/tools list incl. `path_test`, paired-test table, promote +
  post-move, trust boundaries, `patch` off, lifecycle), §Testing
  (`author_task_test`/`run_task_test`, 120 s timeout, job-cache caveat).
- `research/path-kinds-round8-project-anchored-path-kinds.md` — corrected
  project-anchored model, `.find(:current)` discipline + user-store trap,
  paired-test table, BASEDIR/`resolve_path` Path-vs-String migration, round-9
  disposition record (items 1-13, incl. the three-way spelling agreement and
  `scout test` CLI collision).
- `tmp/notes/round9-baseline.md` — engine identity (md5 `7ac34d05…`, HEAD
  `4680bd9`, read-only), ScoutCoder no-git-anchor, probe_01 references to the
  `test` op, post-repair suite state (10/57 → green), `path_authorize!` drift
  note.
- `tmp/notes/round9-smoke.md` — smoke construction contracts, stages, envelope
  discipline, 14 tests / 76 assertions.
- `tmp/notes/round9-refactor.md` — five-file split, md5s, behavior-preservation
  method, scratch-workflow probe (`ScratchProbe`), load-order contract.

scout-ai engine (`/home/mvazque2/git/scout-ai`):
- `lib/scout/llm/agent/path.rb` — 32-45 (`DEFAULT_CAPABILITIES`, `test =>
  false`), 47-56 (`GENERIC_OPERATIONS`, `SPECIAL_OPERATIONS = %w[validate test
  promote smoke patch]`, `BUILT_IN_OPERATIONS`), 58-72 (`PATH_HANDLER_TYPES`
  content/full, `PATH_AUTHORIZATION_MODES` read/write), 114-258
  (`register_path_kind`: normalization, `path_pin_roots!` call, hook
  validation, custom-op normalization at 191, atomic registration w/ rollback),
  264-306 (`DEFAULT_PATH_MAP = :current`, `path_map_option`,
  `path_kind_effective_map`, `path_pin_roots!`), 163-176
  (`path_validate_kind_hooks!` incl. `resolve`), 335-379 (root validation),
  434-560 (custom-op spec normalization; built-in collision raise at ~539),
  523-620 (`path_normalize_custom_operations`, `path_normalize_operation_overrides`),
  690-770 (`install_path_tools`: built-in tools + ONE aggregated tool per
  custom op; `path_custom_tool_definition`: exact-contract collision, forced
  `required = ["kind","path"] + …`, reserved-argument collision),
  770-870 (`path_contract_differences` normalization rules), 870-950
  (`path_dispatch` custom flow: resolve → authorize(mode) → :content/:full),
  950-1030 (`path_tool_definition`: per-op schemas, `"validate"/"test"` case
  comment), 1098-1145 (`resolve_path`: custom `resolve` preference, BASEDIR
  substitution, `root[path]`, `set_extension`, `.find(path_map)`), 1142-1175
  (`path_authorize!`), 1240-1330 (`path_promote`: declarative destination,
  both-endpoint authorization, no-clobber/overwrite, engine move, post_move
  hook args merge), 1420-1440 (`%w[validate test smoke]` define_method loop →
  `path_kind_operation`), 1450-1475 (`path_kind_operation` funnel).
- `lib/scout/llm/agent/path/workflow_kinds.rb` — 31-68
  (`integrate_workflow_path_kinds`: local-Module + namespace-local `PATH_KINDS`
  discovery, deep-copy, cross-workflow name collision), 70-100 (Hash/Array
  normalization).
- `doc/developer/PathEngine.md` — §3 (registration shape, capabilities,
  hooks incl. `"test"`), §6 (custom-operation declaration + aggregation), §7
  (parameter collision policy), §8 (callback contract + trust boundary), §2
  (path maps / pinning).

scout-gear / scout-ai test layout (comparison):
- `~/git/scout-gear/test/**`, `~/git/scout-ai/test/**` — same line-1
  `test_helper` require idiom, `test/scout/**` mirroring `lib/scout/**` (grep
  evidence); invocation `ruby -Ilib -Itest <file>` (round-8 note re `scout test`
  CLI collision).

*Unread items: none — every file cited above was read (in whole or in the
cited range) this round. Line numbers for `path.rb` internals are from the
current file as read; the engine is uncommitted-drift-prone, so re-verify line
numbers at build time and re-pin the md5.*
