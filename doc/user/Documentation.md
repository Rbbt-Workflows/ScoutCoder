# Documentation lookup and the ScoutCoder: convention

The documentation tasks are most useful when an agent needs Scout-specific
context before touching code. The authoring and inspection tasks are the
normal working loop for developing or auditing workflow code.

## The discovery loop

ScoutCoder's documentation lookup covers both the core Scout ecosystem and
any installed Scout workflow. It indexes a fixed list of Scout repository
checkouts plus the `README.md`, `doc*/`, and `research/` directories of
installed workflows (resolution order and the repository list:
[doc/developer/Layout.md](../developer/Layout.md) § "Documentation lookup
sources and repo resolution").

The intended loop:

1. `help_list_repos` — the Scout repository checkouts known to ScoutCoder
   (use when you know you need framework documentation but not where it
   lives).
2. `help_list_workflows` — the workflows installed and available (another
   kind of documentation source).
3. `help_list_repo_documents` — the document identifiers of one repo or
   workflow.
4. `help_get_repo_document` — the raw markdown of one document.
5. `help_overview` — a generated guide, only when the deterministic tasks
   cannot localize the topic (relatively expensive: one model call over
   the fixed repository set).
6. `help_workflow` — the `workflow.md`/`README.md` of any loadable
   workflow.

Task-entry detail for each (inputs, semantics, failure modes) is in the
README `# Tasks` section.

## The ScoutCoder: documentation-improvement convention

When developing code in ruby using the Scout/Rbbt framework, if you
struggle with some detail that you had to figure out but could be better
explained in the documentation, please make a note so can be revised at a
later time to improve the documentation. The format for these notes is a
ruby comment, of possibly multiple lines, starting with the tag
'ScoutCoder:', followed by a statement that describes what you had to
learn to write the good version. As in this example:

```ruby

# ScoutCoder: when using TSV.traverse you can tell it to save the result into :stream,
# with returns an IO inmediately and write into the write end in parallel

io = TSV.traverser tsv, into: :stream do |key,value|
    values.first
end

Open.consume_stream io

```
