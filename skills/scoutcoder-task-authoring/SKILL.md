---
name: scoutcoder-task-authoring
description: Author native Ruby tasks in a Scout workflow. Use for the task DSL, file or value inputs, dependencies and inherited inputs, compute and canfail policies, result types, exports, and the ScoutCoder task draft-to-execution lifecycle.
---

# Author a Ruby workflow task

Read the target checkout's workflow.rb and one neighboring task. Identify the workflow module, how project task files are loaded, and how the intended consumer invokes exported tasks. Use the active workflow libdir when working in a subdirectory. For Python function registration use [Python task authoring](../scoutcoder-python-task-authoring/SKILL.md).

## Start with one callable task

For a workflow named TextTools, write this source with `path_write(kind: "task", path: "line_count", content: ...)`. Substitute the real workflow module. The virtual path is relative to the kind root and omits the extension.

```ruby
module TextTools
  desc "Count nonblank lines in a UTF-8 text file."
  input :source_file, :file, "Path to the UTF-8 text file to read", nil, required: true
  task :line_count => :integer do |source_file|
    File.foreach(source_file, encoding: "UTF-8").count { |line| !line.strip.empty? }
  end
end
```

Put ordinary task definitions inside the workflow module. Keep the operation in the task block unless a real caller shares the logic. Declarations attach to the next task. Block arguments receive its own inputs in declaration order. Give the primary result a matching Scout type. Use `extension :sif`, for example, when consumers need a particular suffix. Keep auxiliary files under the job's `files_dir`.

## Compose tasks through dependencies

Write a second task, virtual path `line_report`, once the first one runs:

```ruby
module TextTools
  desc "Report the number of nonblank lines in the source file."
  dep :line_count
  task :line_report => :string do
    "Nonblank lines: #{step(:line_count).load}"
  end
end
```

Call `line_report` with `source_file`. Scout forwards it to `line_count`. The parent has no positional arguments of its own. Use `.load` for a dependency's typed value, `.path` for its result filename after production, and a declared dependency when its execution and provenance belong to the graph. Use `dep OtherWorkflow, :task_name` after loading the other workflow by the project's convention.

For fixed inputs, mapping earlier Steps into child inputs, dynamic dependencies, optional failures, streaming or deferred execution, read [Inputs and dependencies](contracts.md). The same guide covers `:required`, `:noload`, `:nofile`, `:asfile` and the existing-filename rule.

## Exercise the task through ScoutCoder

1. Draft with kind `task` at the default `tmp` location. Run `path_validate` for syntax and declaration shape and `path_smoke` for workflow loading and registration. A smoke receipt with `executed=false` still needs a behavior check.
2. Create a small fixture with Workspace in the target checkout, e.g. `printf 'A\n\nB\n' > lines.txt` in a disposable checkout. For a workflow loading Ruby drafts through LiveWorkflow, run the draft when it is callable. Otherwise promote and wire it first. Call `debug_task` with `workflow: "TextTools"`, `task: "line_count"` and inputs JSON `{"source_file":"lines.txt"}`. Expect integer 2. Invoke `line_report` with the same input and expect `Nonblank lines: 2`.
3. For a permanent behavioral check, write a Ruby Test::Unit test through kind `test_file`, virtual path `task/line_count`, using the project's test bootstrap. Execute it with `path_run(kind: "test_file", path: "task/line_count", scope: "file")`. Assert the observed value and, for a file consumer, exercise a real file.
4. Promote the source with `path_promote(kind: "task", path: "line_count")`. Default physical locations are `share/tasks` for drafts and `lib/<workflow>/tasks` for project sources. Promote a tmp test separately. Confirm the project loader includes the promoted source. Add the project's usual require only if needed. Apply its export convention when the task should be exposed to agents. Registration and export are distinct.
5. After final wiring and export, force a reload of the owning checkout
   in the consumer's runtime. Use native `debug_task` with
   `workflow: "ScoutCoder"`, `task: "reload_workflow"`, the checkout
   `root` in `inputs`, and `clean: true`. From the intended caller,
   invoke the exported `line_count` on the fixture and check for `2`.
   See [the reload procedure](../../doc/user/PathKinds.md#force-the-reload-and-verify-consumer-access).

For behavioral verification after changing task code, recompute the addressed workflow job: use `debug_task` with `clean: true`, or `refresh: refresh` or `refresh: deep_refresh` when invoking the exported task normally. A fresh `path_run(kind: "test_file")` execution does not refresh Scout jobs invoked inside the test. Regression tests that verify current task behavior should explicitly refresh those jobs. Editing source files does not invalidate completed results.

If CLI help and the live agent disagree, compare the target root, registered signature, supplied input and effective job input for that invocation. Inspect the job receipt before repeating a reload or a clean. Workspace is useful for fixtures and inspecting output. Native invocation tests the workflow registration the consumer uses.
