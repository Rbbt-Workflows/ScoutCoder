# Workflow and repository `README.md`

How Scout parses a workflow README and what each region is for. Verified
against scout-gear `lib/scout/workflow/documentation.rb`
(`Workflow.parse_workflow_doc`, gem 10.13.1) — when behavior matters,
re-check against the current source.

## The parsing contract

`documentation_markdown` prefers `workflow.md` beside the workflow's
`libdir` and falls back to `README.md`. The parser then slices it:

1. **Title** — `doc_parse_first_line`: the first line becomes the title
   only when followed by a blank line (`first-line\n\nrest`). Everything
   after that blank line continues as the document.
2. **Description** — `doc_parse_up_to doc, /^# Tasks/i`: everything from
   after the title up to (not including) the first `# Tasks` heading
   (case-insensitive). This text is what `scout workflow help`-style CLI
   output and HTML templates show, and what agents receive at workflow
   introduction when no `doc/user/README.md` override exists.
3. **Task section** — from `# Tasks` up to the next single-`#` heading.
   `#`-level sections after the task section are *not* part of the task
   index (the parser stops at the first `/^#[^#]/` after `# Tasks`).
4. **Task entries** — split on `/^## (.*)/`: each `## name` chunk becomes
   one entry; empty descriptions are dropped.

What this means in practice:

- Everything below the task entries (or below any later `#` heading) is
  humans-only: installation, references, contributing, licensing. It is
  ignored by the CLI, templates and agent tooling — use it freely.
- Inside the description region, further headings are allowed; the parser
  only looks for `# Tasks`.
- If no `# Tasks` heading exists, the whole README is description (main
  repositories like scout-gear or scout-ai work this way).

## Task entry shape

```markdown
## task_name
One-line description of what the task does.

Then one or more paragraphs with usage, inputs, outputs, dependencies,
examples or caveats.
```

Rules from `WritingDocumentation.md`:

- The task index must start with a level-one `# Tasks` heading on its own
  line.
- Each task heading must be exactly `## task_name` — the declared task
  name, no decoration, no extra `#`.
- Do not use additional `#` or `##` headings *inside* a task description:
  the parser uses headings as task boundaries. Use paragraphs, lists,
  bold text or indented code instead.
- Keep task names aligned with the actually declared tasks; a documented
  task that no longer exists logs `Documentation for <task>, but not a
  <Workflow> task` at load time.
- The first line after the heading is the one-liner used in compact
  listings; make it a complete sentence describing the operation.

## Keeping the README in sync

- **Same-change rule:** when changing a task, update its README entry in
  the same change. When adding/removing a task, check the README against
  `list_tasks` output and test examples where practical.
- **`document_task`:** ScoutCoder's `document_task` task adds or replaces
  one `## <task_name>` entry in the README task section — the
  documentation half of promotion. A draft task carries its docs in a
  `desc` under `share/tasks`; on promotion into `lib/<workflow>/tasks` the
  `desc` is dropped and the README entry becomes the single source.
- **Example discipline:** examples should be small and runnable; keep
  them consistent with current APIs and task names, and document inputs
  and return types using the workflow's public names.

## Minimal skeleton

```markdown
A workflow for transforming examples.

This workflow provides reusable tasks for ... . Use it when ... .

# Tasks

## greet
Greet a supplied name.

The `name` input is optional and the task returns a string.

## another_task
One-line description of the next task.

Installation notes, references and other humans-only material go here,
after the task entries.
```
