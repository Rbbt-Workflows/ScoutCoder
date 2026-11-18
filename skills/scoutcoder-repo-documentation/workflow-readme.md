# Updating a task entry

1. For a draft under `share/tasks`, keep its description with the draft. On promotion into `lib/<workflow>/tasks`, move the description into the parsed task index and remove the duplicate draft `desc`. Keep input descriptions on the declarations.
2. For a workflow using the root README, ScoutCoder’s `document_task` adds or replaces one task entry. If the workflow supplies `workflow.md`, edit that file so the parser sees the change.
3. Compare the exact heading with the loaded task name. Inspect the resulting help, including the last task in the index if you added a section after it. Update the agent introduction only if the edit changes what a caller should choose or do first.

For the Markdown skeleton and heading rules, retrieve the scout-gear guide named in [the skill](SKILL.md) and read **Repository README and workflow task index**.
