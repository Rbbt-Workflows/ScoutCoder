---
name: scoutcoder-help-discovery
description: Look up Scout framework and workflow documentation through ScoutCoder's help_* tasks before writing Scout code. Use when a bout needs framework semantics, a task/entity/TSV/Path-Engine contract, or an installed workflow's README/doc/research content and local docs are insufficient. Covers the deterministic lookup loop (help_list_repos, help_list_workflows, help_list_repo_documents, help_get_repo_document, help_workflow) versus the model-generated help_overview, cost sizing, and when to read docs directly instead of calling ScoutCoder. Triggers help_list_repos, help_list_workflows, help_list_repo_documents, help_get_repo_document, help_overview, help_workflow, Scout documentation, which repo documents, workflow README, framework semantics, scout-gear docs, how does TSV or the Path Engine work.
---

# Scout documentation discovery with ScoutCoder

## What this skill covers

When to reach for ScoutCoder's `help_*` lookup loop during development,
how to walk it in the cheap-to-expensive order, and when to skip it in
favor of reading repository docs directly. Authoring and testing workflow
code are separate skills (`scoutcoder-entity-authoring`,
`scoutcoder-path-kinds-lifecycle`).

## The decision: call ScoutCoder or read docs directly

| Situation | Do this |
|---|---|
| You know the file (repo + path) | Read it directly; no task needed |
| You know the repo but not the document | `help_list_repo_documents` then `help_get_repo_document` |
| You do not know which repo holds the topic | `help_list_repos` first; the fixed repo list plus installed workflows is the search space |
| You need another workflow's overview | `help_workflow` (loads its `workflow.md`/`README.md`) or `help_list_workflows` |
| Deterministic tasks cannot localize the topic | `help_overview` — model-generated guide, one model call over the fixed repo set; LAST resort, not a first move |

Cheap-first rule: list → fetch one document → only escalate to
`help_overview` when the deterministic lookups have failed to localize the
topic.

## What the lookup actually indexes

Fixed Scout repository checkouts (scout-gear, scout-essentials, scout-camp,
scout-ai, scout-rig, when present under `~/git`) plus the `README.md`,
`doc*/` and `research/` directories of installed workflows. Resolution
order and the repo list are owned by
[doc/developer/Layout.md](../../doc/developer/Layout.md) § "Documentation
lookup sources and repo resolution" — do not restate it here.

## Operational cautions

- `help_get_repo_document` returns raw markdown; use document identifiers
  exactly as `help_list_repo_documents` reports them.
- `help_overview` is relatively expensive; call it only after the
  deterministic loop failed, and say so in the report when you do.
- The result is the evidence: cite the repo, document identifier and the
  fetched text (job path), not a paraphrase.
- Cross-check anything load-bearing: documentation describes the intended
  contract; when behavior matters, verify with a small representative run.

## The ScoutCoder: comment convention (side effect of discovery)

When you had to figure out a Scout detail that the docs should have
covered, leave a `ScoutCoder:` comment at the site (possibly multi-line,
starting with the tag, then what you had to learn). Promoted comments are
the raw material for `document_task` entries and repo-doc improvements.
Full convention: [doc/user/Documentation.md](../../doc/user/Documentation.md).

## Common mistakes

- Calling `help_overview` as the first step (cost, and it may still miss).
- Guessing a document identifier instead of listing first.
- Transcribing fetched docs into chat instead of citing the job/document.
- Assuming help docs prove runtime behavior — they document contracts.

## Going deeper

- Lookup loop detail and task entries: [doc/user/Documentation.md](../../doc/user/Documentation.md),
  README `# Tasks`.
- Which ScoutCoder tool for which need:
  [doc/user/ToolSelection.md](../../doc/user/ToolSelection.md).
