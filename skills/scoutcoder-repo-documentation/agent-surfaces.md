# Agent-facing documentation surfaces

Two repository features exist specifically for the agents a workflow is
introduced to: the `doc/user/README.md` override and the `skills/`
directory. They change what agents receive, not what humans read.

## `doc/user/README.md` — the agent-facing override

When a workflow is introduced to an agent — normally when the workflow's
tooling is made available — the agent is shown the workflow's
description. Without an override that description is the README text
between the first line and the `# Tasks` heading (see
[workflow-readme.md](workflow-readme.md)).

If `doc/user/README.md` is present, *that file* is shown instead. This is
a chance to make the introduction more focused: the main `README.md` may
contain things agents do not care about (task-reference bulk, maintainer
notes), while `doc/user/README.md` can be a tight agent-oriented index.

Keep in mind:

- The override replaces the description *for agents*; the CLI and HTML
  surfaces keep using the README description. Both must stay truthful.
- A good agent-facing intro points to the operational guides
  (`doc/user/*.md`), names the skills the workflow ships, and states the
  entry points (which task to call first for common needs).
- It is documentation, not configuration: creating the file changes what
  agents are told, so review it with the same care as any doc change.
- If the workflow has no agent audience, do not create the file just to
  mirror the README.

## `skills/` — reusable agent guidance

Workflow repos intended for agent tooling may include a `./skills`
directory following normal skills conventions. When a workflow is
introduced to an agent:

1. Any skills present are presented to the agent, so it knows they exist
   and what they cover.
2. The skill folders are added to the agent's sandbox, so the agent can
   read them with the Workspace workflow's `read` tool.

Skill anatomy (as used in this repo):

```
skills/<skill-name>/
  SKILL.md          # frontmatter (name, description) + the skill body
  <detail>.md       # optional additional files the skill links to
```

- `name` in the frontmatter should match the directory name.
- The `description` is the trigger surface: it should say when to use the
  skill and what it covers. Existing Scout skills also carry a
  `Triggers ...` sentence listing trigger phrases; keep that convention
  when adding skills here.
- The body follows the established shape: *What this skill covers* (and
  what it delegates to sibling skills), a compact decision table or
  recipe, *Common mistakes*, and *Going deeper* links to the canonical
  docs.
- Put stable rules in `SKILL.md` and depth in additional files, linked
  from the top; the agent loads the detail files only when the bout
  needs them.
- Reference canonical documentation by project-qualified path rather
  than restating it — when the canonical source changes, the skill
  should not contradict it.

## Consistency obligations

Because three surfaces describe one workflow (README description,
`doc/user/README.md` override, skills), keep them consistent:

- When a task is added, removed or renamed, the README task entry, any
  override text that mentions it, and any skill table that lists it must
  move together.
- When the doc set changes, update the override's pointers and the
  skills' *Going deeper* links.
- Prefer updating the canonical guide over maintaining a parallel copy
  in a skill.
