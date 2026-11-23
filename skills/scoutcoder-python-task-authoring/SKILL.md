---
name: scoutcoder-python-task-authoring
description: Author and test PythonWorkflow tasks with ScoutCoder's python_task kind. Use for scout.task registration, Python annotations, file paths versus text, list and boolean inputs, return serialization, controlled errors, and composing a Python task with Ruby dependencies.
---

# Author a PythonWorkflow task

Use a Python task for a computation that naturally belongs in Python and should be callable as a Scout job. Keep the dependency graph in the workflow. Choose one small input whose expected result you can check through the actual caller.

## Write one registered function

Use virtual path `count_nonblank` and kind `python_task`. Write this complete file as the draft:

```python
"""Count records in a text file supplied by Scout."""

from pathlib import Path

import scout
from scout.task_errors import ScoutTaskError


def count_nonblank(source_file: Path) -> int:
    """Count nonblank lines in a UTF-8 text file.

    Args:
        source_file: Path to the text file, including a producing job's result file.
    """
    try:
        with Path(source_file).open(encoding="utf-8") as source:
            return sum(1 for line in source if line.strip())
    except (OSError, UnicodeError) as exc:
        raise ScoutTaskError(f"Cannot read {source_file}: {exc}") from exc


scout.task(count_nonblank)
```

Keep the function and its explicit module-level `scout.task(function)` registration in the task file. Metadata discovery executes that file, so keep import-time work small and stdout clean. The function docstring preamble becomes the description and `Args:` entries document parameter names. The annotations determine types. Put expensive imports inside the function where practical.

Scout distinguishes file inputs from value inputs. A file input identifies a resource to read, so the task receives a filename. A value input represents the data itself, but Scout also permits callers to supply that data through an existing file: for ordinary string inputs, Scout can load the file before calling the task.

PythonWorkflow translates Python annotations into these Scout input types. Use `Path` when the Python function needs the filename and will open the file itself. Use `str` when the function needs the text content, whether supplied directly or loaded by Scout. If a string must remain literal even when it matches an existing filename, the Scout input requires `noload: true`; Python annotations do not currently expose that option directly.

## Check the file boundary

| Function contract | Metadata → Scout input | Python invocation |
|---|---|---|
| `source_file: Path` | `path` → `:file` | Receives a filename string from the generated CLI. Use `Path(source_file)` to open it. |
| `text: str` | `string` → `:string` | Receives text. Scout may load the contents when a supplied string names an existing file. |
| `samples: list[str]` | `list[string]` → `:array` | Pass a JSON array such as `["A","B"]`; argv preserves the items. |
| `sources: list[Path]` | `list[path]` → `:file_array` | Supply an array of filenames and open each with Path. |
| `limit: int = 10` or `include_empty: bool = False` | `integer` or `boolean` plus the default | Omit the option to use the default. Supply typed numbers and booleans through debug_task. |

The Ruby adapter maps the generated parameter metadata to its type and required flag. It does not expose a general Python annotation for `:noload` or `:nofile`. If an identifier must remain literal even when it names an existing file, design an explicit literal-value interface (for example, a native Ruby task declaring `input :label, :string, "Literal label", nil, noload: true`). Passing that value through another ordinary Scout string input can reintroduce loading. See [Ruby input and dependency contracts](../scoutcoder-task-authoring/contracts.md).

Use explicit defaults for optional parameters. Supply nonempty lists to the generated list CLI (`nargs="+"`). A scalar string supplied for a list may be expanded as lines from an existing file before comma splitting. For postponed annotations, check the generated metadata on the installed runner: `source_file` must be `path`. Older runners can silently classify the string annotation as `string`. A Python task should only accept inline file contents if that is part of its public contract.

## Draft, promote and execute

1. Use `path_write`, `path_validate`, then `path_smoke` with `kind: "python_task", path: "count_nonblank"`. Validation checks source shape. Smoke checks workflow loading and registration. Neither executes the function on the fixture.
2. Promote with `path_promote` using the same kind and path. The usual physical locations are `share/python_tasks/count_nonblank.py` and `python/tasks/count_nonblank.py`. In the supplied implementation extending `PythonWorkflow` loads tasks from `libdir.python.tasks.find`; setting `python_task_dir` also loads that directory. In a workflow already configured this way, promotion into the discovered directory is sufficient for a fresh load. Follow the target's export convention after discovery if agents need the task.
3. From the target checkout, use a disposable fixture containing `A`, a blank line and `B`. Call `debug_task` with the target workflow name, task `count_nonblank` and inputs JSON `{"source_file":"lines.txt"}`. Expect integer 2. For composition, also pass the actual result filename of a producer. Python-side tests use kind `test_file`, virtual path `python_task/count_nonblank`, `location: "python"`, and run with `path_run` at that location.
4. After modifying Python task code, distinguish registration from execution. Reload the workflow when its registered signature or metadata must change; use `debug_task(clean: true)` or an exported call with `refresh: refresh` or `refresh: deep_refresh` to recompute the task result. Existing Scout jobs are not invalidated by source edits. When a Ruby regression test invokes a PythonWorkflow task, refresh the inner job explicitly; rerunning the test file alone does not guarantee that the Python function executes again.

### Localize a disagreement with one comparison

| Question | Check |
|---|---|
| What did the Python runner describe? | In the task environment, run `python python/tasks/count_nonblank.py --scout-metadata`. Expect parameter type `path`, required true, and return type `integer`. |
| What did a fresh workflow register? | `scout task workflow.rb count_nonblank -h` should show `source_file=<file>`. |
| What did the actual consumer use? | Run the tiny fixture through `debug_task`. If it fails, inspect the target checkout, registered input type and job's supplied versus effective input. Successful standalone Python execution checks only the Python side. |

## Dependencies, results and errors

Define dependencies with Ruby's `dep` DSL. For example, after the Python task loads, a Ruby task can consume its result directly:

```ruby
module TextTools
  desc "Label the number of nonblank lines in the source file."
  dep :count_nonblank
  task :count_summary => :string do
    "Nonblank lines: #{step(:count_nonblank).load}"
  end
end
```

The caller supplies the inherited `source_file` to `count_summary`. To pass a producer's file *into* the Python job, declare `dep :make_text` first and then `dep :count_nonblank, source_file: :make_text` on the same parent. For scheduling, optional failure and dynamic dependencies see [Inputs and dependencies](../scoutcoder-task-authoring/contracts.md).

Return the primary value. A Python `Path` return maps to Scout `:string`; returning the name of a file does not publish its contents as the main result. For a text artifact, return its text or bytes and use a standalone docstring line such as `Extension: sif` to set the suffix. Use the running job's `SCOUT_JOB_FILES_DIR` for auxiliary files. Standalone execution and metadata discovery do not supply that job context.

Send diagnostics to stderr. The Python runner writes results to stdout. The supplied Ruby bridge first attempts JSON decoding, then falls back to newline splitting for arrays or stripped output for other types. For a byte-exact result, including significant leading or trailing whitespace, check the actual Scout result file against the expected bytes. A successful standalone `--scout-output` test covers a different output path.

Raise `ScoutTaskError` for an expected task-level failure. The bridge reconstructs it as `PythonWorkflow::PythonTaskException` with its Python traceback. Use a missing-file fixture to check the message. Use Ruby dependency `canfail: true` only when the parent has a defined result for that failure.
