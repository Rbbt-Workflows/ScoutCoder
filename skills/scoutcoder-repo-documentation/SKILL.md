---
name: scoutcoder-repo-documentation
description: Write or review Scout repository documentation, including the agent introduction, parsed workflow README, task and input help, CLI guides, and contributor documentation.
---

# Write Scout repository documentation

Choose the surface by what the reader is trying to do.

- **Introduce the tooling.** Agents start at `doc/user/README.md` when present, with the root workflow description as fallback. Cover the main uses, the first call for each, and one short input-to-result example. Link deeper guides where needed. Skills are linked automatically.
- **Describe the workflow.** In the parsed README (or `workflow.md` when present), put a blank line after the title. Follow the overview with `# Tasks`, then one `## task_name` per public task. The next level-one heading closes the index.
- **Document a call.** Give the operation and result in the first sentence. Explain the meaning and accepted form of each input in its declaration. Use the task entry for output shape, interactions and caveats. For CLI use, show a command and its observable result in `doc/user/`.
- **Orient a contributor.** Durable implementation guidance belongs in `doc/developer/`. For ongoing work, consult temporary working artifacts. Strip phase names, progress reports and handoffs from all durable descriptions.

## Look up a convention

Use ScoutCoder’s `help_get_repo_document` with these inputs:

```json
{"repo":"scout-gear","document":"developer/WritingDocumentation.md"}
```

The task returns the full guide. Go directly to the heading that matches the edit:

| Editing decision | Heading in the guide |
| --- | --- |
| Where a fact belongs | Where information belongs |
| How much agents need up front | Agent introduction |
| README syntax and parser boundaries | Repository README and workflow task index |
| Wording a task or an input | Task and input descriptions |
| Documenting an executable | CLI documentation |
| Checking the result | Review from a clean checkout |

If the installed repository lists a different identifier, use `help_list_repo_documents` with the same `repo` and select the returned identifier. For the ScoutCoder task-editing procedure, see [Updating a task entry](workflow-readme.md).
