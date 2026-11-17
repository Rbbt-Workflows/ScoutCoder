# Where documentation material belongs

Scout repositories use three complementary documentation areas. Keep them
distinct rather than putting every note into one README; the split is by
audience and provenance. Summarized from scout-gear
`doc/developer/WritingDocumentation.md`, with the two-layer contract from
scout-essentials `research/doc-structure.md`.

## The areas

| Area | Audience | Standard |
|---|---|---|
| `doc/user/` | People building or running workflows — task-oriented | Normative, stable, verified |
| `doc/developer/` | People changing Scout itself — mechanism-oriented | Normative, may cite classes/methods/files |
| `research/` | Future maintainers — investigation records | Non-normative, may be outdated |
| `doc/Improvements.md` | Maintainers | Numbered defect/improvement ledger |

`doc/StartHere.md`, where present, is the entry point and reading-path
index; update its navigation links (and the root README's, when
appropriate) when adding a guide.

## Placement table

| Kind of material | Destination |
|---|---|
| Core, verified behavior a user needs | `doc/user/<Topic>.md` |
| Core, verified mechanism a maintainer needs | `doc/developer/<Topic>.md` |
| Known defect / improvement candidate | `doc/Improvements.md` |
| Hazard, heuristic, environment-specific behavior | `research/<topic>.md` |
| One-off verification transcript | Nowhere — write a regression test instead |
| Cross-repo attribution of a constant | `research/ecosystem-attribution.md` (or that repo's equivalent) |

## What each area should contain

### `doc/user/`

- Clear title and short statement of scope; intended audience and when to
  use the feature.
- Core concepts and a minimal working example; the normal API or CLI
  usage with inputs and outputs.
- Common mistakes, limitations, and links to related guides.
- Prefer concepts and stable behavior over internal file names. Never
  present an unverified implementation detail as user-facing behavior:
  probe it, or label it as a limitation/open question.

### `doc/developer/`

- Audience and subsystem map; lifecycle or data flow; source locations
  (verify them — implementation details drift); extension procedure;
  compatibility concerns; known issues.
- Explain *why* the code behaves as it does, not only what a method is
  called.

### `research/`

- Non-normative investigation records: probes, experiments, competing
  hypotheses, observations, conclusions not yet stable enough for `doc/`.
- Declare status explicitly, e.g. `**Status:** Non-normative
  investigation artifact. May be outdated.`
- Preserve the causal trail: question, commands/tests, observations,
  interpretation, uncertainty, conclusion. Include dates, versions or
  environment details that affect the result.
- Research is *evidence for* documentation, not a substitute. Once a
  finding is validated, summarize the supported behavior in the right
  `doc/` guide; keep a link to the research artifact when its provenance
  matters. Do not silently turn "not found" into "does not exist".

## Choosing a new file vs extending an existing one

Before adding a file, inspect `doc/StartHere.md` (or the doc index) and
the repository README. Add a new guide only when the subject has a
coherent audience and purpose; otherwise extend the closest existing
guide. Then update navigation in both places as needed.

## Evidence hygiene (from the documentation practices)

- Label claims by their evidence: verified against source, observed in an
  executed probe, or documented elsewhere.
- `doc/` pages cite `file:line` anchors and regression tests, not probe
  transcripts — transcripts are process, not product.
- Promote along the ladder: probe artifacts → `research/` → `doc/`, with
  the verified facts distilled and the unverifiable dropped.
- Route live code defects to `Improvements.md` with a receipt; never
  document broken behavior as normal.

## Review checklist before finishing

1. Is the audience clear (`doc/user`, `doc/developer`, `research`)?
2. Are claims supported by current source, tests, or a cited
   investigation?
3. Are examples consistent with current APIs and task names?
4. Does `doc/StartHere.md` or the root README need a navigation link?
5. For a workflow README: one `# Tasks` section, a `##` entry per
   documented task, no nested task headings?
6. Are limitations and uncertainty stated instead of hidden?
