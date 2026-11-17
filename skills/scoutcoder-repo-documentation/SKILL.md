---
name: scoutcoder-repo-documentation
description: Write or review documentation for Scout repositories and workflows - README.md description slicing, the "# Tasks" index, doc/user and doc/developer guides, research notes, agent-facing doc/user/README.md overrides, and skills folders. Use when creating or editing a README, deciding where new material belongs (doc/user, doc/developer, research), documenting a workflow task in the README task index, writing an agent-facing doc/user/README.md, or adding a skills/ folder. Triggers README.md, Tasks section, workflow description, doc/user, doc/developer, research note, documentation guidelines, document_task, agent introduction, skills folder, SKILL.md, where does new material go.
---

# Scout repository and workflow documentation

## What this skill covers

The rules that make Scout repository documentation work with the tooling
that consumes it: how the README is parsed into title/description/task
index, where each kind of material belongs across the three documentation
areas, the agent-facing override and skills conventions, and the checks to
run before declaring documentation done. For *looking up* existing
documentation use the `scoutcoder-help-discovery` skill; this skill is for
*writing* it.

Detail files, loaded when the bout needs them:

- [Workflow and repo README.md](workflow-readme.md) — the `# Tasks` parser
  contract, title/description slicing, what is ignored below the task
  section, and the `document_task` task.
- [Where material belongs](doc-areas.md) — `doc/user/` vs `doc/developer/`
  vs `research/` (and `Improvements.md`), with the placement table and
  promotion path.
- [Agent-facing surfaces](agent-surfaces.md) — `doc/user/README.md`
  override, the `skills/` directory convention, and what agents actually
  receive when a workflow is introduced.
- [CLI tools and other repos](other-repos.md) — documenting command-line
  tools, main repositories (no `# Tasks` section), and cross-repo
  attribution.

## The one-paragraph version

A workflow README's first line is its title; everything between that first
line and the `# Tasks` heading is its description (shown in the CLI, HTML
and agent introduction); below the task entries, everything up to the next
`#` heading is read by humans only and is the right place for installation
notes. `doc/user/` is task-oriented normative guidance, `doc/developer/`
is mechanism documentation, `research/` holds non-normative investigation
records — pick by audience and provenance, not by size. A
`doc/user/README.md`, when present, replaces the README description for
agents, and a `skills/` directory is presented to agents and mounted into
their sandbox when the workflow is introduced.

## Decision table

| You are documenting... | It goes in... | Critical rule |
|---|---|---|
| A workflow task | `## task_name` entry in the README `# Tasks` section | Heading exactly `## task_name`; no nested `#`/`##` inside the entry |
| The workflow itself | First line (title) + paragraphs before `# Tasks` in `README.md` | First line must end with a blank line; description ends at `/^# Tasks/i` |
| Material agents need at introduction | `doc/user/README.md` (agent-facing override) | Replaces the README description for agents; keep it agent-useful, not repo bookkeeping |
| Reusable agent guidance | `skills/<skill-name>/SKILL.md` | Standard skill frontmatter (`name`, `description`); referenced from the intro |
| How to *use* a capability | `doc/user/<Topic>.md` | Task-oriented; no unverified implementation detail |
| How a subsystem *works* | `doc/developer/<Topic>.md` | Class/method/file names allowed; verify `file:line` claims |
| Probes, hypotheses, investigation trails | `research/<topic>.md` | Marked non-normative; evidence for docs, not a substitute |
| A task's entry in the README | `document_task` task or the same-change edit | Update in the same change as the task code |

## Common mistakes

- Putting a second `#`-level heading inside a task entry — the parser
  treats the next heading as a task boundary.
- Omitting the blank line after the README's first line; the title only
  parses as `first-line\n\nrest`.
- Writing installation or contributor detail above `# Tasks` — that
  region is the workflow description; humans-only material belongs below
  the task entries.
- Assuming the README description is what agents see — with
  `doc/user/README.md` present, agents get that file instead.
- Duplicating a `desc` in `share/tasks` and a README entry after
  promotion; promotion drops the `desc` and the README entry becomes the
  single source.
- Turning an unprobed claim into `doc/` guidance; if it is not verified,
  it belongs in `research/` or stays a `ScoutCoder:` comment.

## Going deeper

Canonical sources: scout-gear `doc/developer/WritingDocumentation.md`
(documentation areas, README format, review checklist — reachable through
`help_get_repo_document`) and the parsing semantics in scout-gear
`lib/scout/workflow/documentation.rb` (`Workflow.parse_workflow_doc`).
Local detail files in this skill folder (linked above).
