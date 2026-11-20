# Input and dependency contracts

## Choose the meaning of an input

The declaration is `input name, type, description, default, options`. Put `nil` in the default position when supplying options without a default. Describe what callers should pass. These three declarations accept the same spelling with different meanings:

| Intended contract | Declaration | If the caller supplies the string `lines.txt` and it names an existing file |
|---|---|---|
| Read a file in the task | `input :source, :file, "Path to the file to read", nil, required: true` | The block gets a resolved file path and opens it. |
| Accept a text value, including text supplied from a file | `input :text, :string, "Text to process, or a file containing it"` | Scout can load that file as a string before the block starts. |
| Accept a literal identifier, including filename-like identifiers | `input :label, :string, "Literal label", nil, noload: true` | The block gets the literal string for a direct string input. |

For an ordinary string that passes Scout's filename heuristic, `Task.format_input` loads an existing non-directory file as the declared type; otherwise that branch deserializes the supplied value. File contents can therefore affect a call even if the author never wrote file I/O. Reserved `"nil"` is converted to nil before this branch. IO and Step inputs take other paths. Test the collision case with an actual file and distinguish its name from its contents.

| Option or type | Scope and consequence |
|---|---|
| `:required => true` | Makes omission an error at job construction. The supplied implementation checks the presence of the input name. Validate explicit nil, empty strings, ranges and file readability separately when they matter. Supply a default for an optional value. |
| `:noload => true` | Suppresses the filename-content branch during direct input formatting. It does not turn off job caching. |
| `:nofile => true` | Also bypasses that branch. Both flags make the ordinary saved-input-file loader return its filename. The flags share these checks; avoid promising that they are interchangeable in every caller or persistence format. Prefer noload when documenting a literal value. |
| `:path` / `:file` | Both wrap a nonempty string as a Scout Path and skip content loading. Assignment additionally calls `.find` for `:file`. Use `:file` for a file the task reads. |
| `:asfile => true` | Suppresses implicit loading and wraps a supplied nonempty string as a Path. The automatic `.find` step belongs to the `:file` type. |
| `:stream => true` on an input | Suppresses implicit filename loading. Choose an input contract that the body can actually consume. Dependency streaming is a separate policy below. |
| `:file_array` and typed arrays | Direct arrays are formatted element by element for `:<type>_array`. Supply an actual array when item boundaries matter. |
| `:jobname => true` | Lets an input participate in choosing the job name. Prefer a string suitable for a name and provide it explicitly when relying on this behavior. |

Saved-input bundles have their own `.as_file`, `.as_path` and `.as_step` handling. Likewise a Step passed as an input is tracked as a dependency, then adapted for the receiving type. Choose a file type when the intended boundary is an upstream job's result path. A result path and its `.files` sidecar directory serve different purposes.

## Set up dependency inputs

- `dep :line_count` forwards inputs accepted by the dependency, including through chains. Declare an input again on the parent only if its body also consumes it. A value fixed on the dependency, e.g. `dep :summarize, precision: 2`, drops out of that branch's inherited input list.
- To feed one task into the next, declare the producer first. For example, `dep :make_text` followed by `dep :line_count, source_file: :make_text` supplies the earlier Step to the file input of line_count. A symbol binding checks already-declared dependencies before a matching parent input. Use distinct names where both could match.
- For data-dependent fan-out, the block form receives `|jobname, options, earlier_steps|`. Return a Step, an options hash, or an array of either. For example, inside a workflow with `task :score` accepting `sample`, use `dep :score do |jobname, options, _|` and return `options[:samples].map { |s| {jobname: "#{jobname}-#{s}", inputs: {sample: s}} }`. Declare `samples` as a parent array input. Consume repeated dependencies via the parent's `dependencies` list.
- Construct a job with `wf.job(:task_name, jobname, inputs)` to inspect its dependency Steps and paths. Execute through `run` for a value or `produce` to materialize a result. For a consumer test use the exported invocation as well.

## Choose a dependency execution policy

Put these options on `dep`. They control how Scout runs that dependency.

| Declaration | Use and behavior |
|---|---|
| `dep :upstream` | Normal dependency scheduling. Scout can stream by default unless explicit streaming is enabled. |
| `dep :large, compute: :produce` | Produce the result without loading its value for the scheduler. Consume the completed file by path. `produce: true` also sets this mode. |
| `dep :records, compute: :stream` | Request a streaming run. Useful with `SCOUT_EXPLICIT_STREAMING=true`. `stream: true` on the dependency also sets it. |
| `dep :optional_annotation, canfail: true, compute: :produce` | Permit a ScoutException from the dependency run. Check `step(:optional_annotation).error?` before consuming it and define what a missing annotation means. `compute: :canfail` is the single-mode spelling. This is scoped error handling; unrelated Ruby exceptions can still abort the parent. |
| `dep :expensive, compute: [false]` | In the supplied engine the scheduler skips a dependency whose normalized mode list includes false. The Step still exists. Check for a usable result before reading it; the parent may have to produce it explicitly. Bare `compute: false` is lost to the builder’s empty-array fallback in this implementation. |

Multiple modes can be expressed as an array, e.g. `compute: [:produce, :canfail]`. Use optional failure only when a correct parent result can be defined on that branch. For a required input quality check, let the failure propagate.

For implementation-level diagnosis, input assignment lives in scout-gear's `lib/scout/workflow/task/inputs.rb`, required-name checking in `workflow/task.rb`, and dependency normalization and execution in `workflow/task/dependencies.rb` and `workflow/step/dependencies.rb` under `lib/scout`.
