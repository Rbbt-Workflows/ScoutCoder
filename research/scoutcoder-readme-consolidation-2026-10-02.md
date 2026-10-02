# ScoutCoder README consolidation (2026-10-02)

## What changed and why

README.md is now the sole documentation file for the ScoutCoder checkout. The
rewrite was driven by a full audit of every `lib/ScoutCoder/tasks/*.rb` against
the old README entries; all 23 task entries were re-derived from current code.

- `doc/developer/Help.md` was deleted. Its content (resolution details for the
  help_* tasks, .md-only listing, identifier-collision caveat across multiple
  `doc*` dirs, ParameterException-on-miss note, "avoid help_overview in
  automated checks" advice) was absorbed into the README help_* entries. Nothing
  unique was lost.
- The stale overview claims were removed: there is no `agent` helper and no
  `share/prompts/` in this checkout (the `agent` helper belongs to
  scout-ai's `AgentWorkflow`, which this workflow does not extend); the
  project-understanding and planning tasks (`summarize_file`, `explain_code`,
  `explore_directory_structure`, `plan`) and the inherited ComputerUse tools
  are not part of this workflow's 23-task list and are no longer described as
  if they were.
- `list_entities` documentation updated to the new behavior: all known
  `Entity` modules (`Entity::MODULES.uniq`), including framework modules such
  as `AssociationItem`, deduplicated; scoped variant noted as
  support-helper-only.
- New `## Layout conventions` section: lib vs share split, the
  `share/entities`/`share/entity_properties` draft convention, `share/test`
  placement, `share/entity/*.identifiers.tsv` as data, `doc/` now absent.
- New `## LiveWorkflow` section (full text quoted in the delegation report).
- `job_info` entry now mentions the info file; `list_tasks` entry no longer
  implies dependencies are absent from the listing (a dependency summary is
  included; it just does not expand dynamic blocks).

## Audit table (23 tasks)

| task | old README lines | verdict | note |
|---|---|---|---|
| define_entity | 206-214 | accurate | identifiers must be non-empty; extend-in-body rejected via AST check |
| define_entity_property | 216-223 | accurate | token-level `property :<name>` requirement |
| list_entities | 225-232 | fixed | was "loaded under ScoutCoder"; now all known Entity modules |
| task_code | 235-241 | accurate | whole-file text, `text_scope: entire_file` |
| task_dependencies | 243-249 | accurate | dynamic blocks with locations, `dynamic_list_is_complete` |
| define_task | 251-290 | accurate | result also carries inspection + registration validation |
| define_helper | 293-316 | accurate | loaded after authored tasks |
| author_helper_test | 318-325 | accurate | EXCL write, not run |
| run_helper_test | 327-334 | accurate | fresh process, timeout default 120 |
| author_task_test | 336-346 | accurate | path derived from task source location |
| run_task_test | 348-359 | accurate | lib on load path, no cache clearing |
| document_task | 361-373 | accurate | needs literal `# Tasks` heading |
| list_tasks | 375-381 | fixed wording | dependency summary IS in each entry |
| task_inputs | 383-389 | accurate | direct + recursive inputs |
| run_task | 391-417 | accurate | `cache_replay` recorded before optional clean |
| job_info | 419-424 | fixed | info file now mentioned |
| job_status | 426-432 | accurate | running flag + timestamps |
| help_list_repos | 434-441 | accurate | REPOS constant |
| help_list_repo_documents | 443-451 | accurate + Help.md absorbed | resolution order, collision caveat |
| help_get_repo_document | 452-461 | accurate + Help.md absorbed | fallback chain, 10-doc miss list |
| help_overview | 463-468 | fixed | documents the LLM call, REPOS-only scope, agent-machinery requirement |
| help_workflow | 470-476 | accurate | autoinstall disabled, workflow.md or README.md |
| help_list_workflows | 477-482 | accurate | installed (rescued) + loaded, uniq.sort |

## Validation

- 23 `## <task>` entries; `Workflow.parse_workflow_doc` over the served
  documentation reports exactly the 23 code task names (missing=[], extra=[]).
- Stale-claim greps all empty: `agent` helper claims, `share/prompts`,
  "loaded under ScoutCoder", `valid_entity` (case-insensitive, whole tree).
- Pure-ASCII check clean.
- All seven test suites green in fresh processes:
  test_LiveWorkflow 9/57, test_entity_tools 13/67, test_workflow_tools 8/35,
  test_document_task 3/5, test_helper_tools 2/10, test_task_test_tools 1/7,
  test_task_test_support 4/15; 0 failures, 0 errors everywhere.

## Notes

- A stale `help_workflow` job under `~/.scout/var/jobs/ScoutCoder/` briefly
  served the old 15142-byte README even after the rewrite; a clean re-run
  (`run_task` with `clean: true`) served the new file. Not a README defect,
  only persistent job caching.
- No Ruby code was changed.
