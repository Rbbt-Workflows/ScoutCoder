# CLI tools, main repositories, and other documentation targets

The README conventions differ by repository kind. Workflow repositories
have a parsed `# Tasks` section; main repositories and standalone CLI
tools do not.

## Main Scout repositories

Repos like scout-gear, scout-essentials or scout-ai are libraries, not
agent workflows. Their README:

- Has no `# Tasks` section; the parser simply never finds one, so the
  whole README is description. There is no task index to maintain.
- Follows the same three documentation areas (`doc/user`,
  `doc/developer`, `research/`) plus `doc/StartHere.md` as the entry
  point with reading paths, and `doc/Improvements.md` as the
  defect/improvement ledger.
- Should keep `doc/StartHere.md` and the README navigation in sync when
  guides are added.

## CLI tools and executables

Scout CLI commands and standalone tools are documented as user-facing
behavior in `doc/user/` (task-oriented: what it does, options, examples),
not as workflow task entries:

- Document each command's purpose, inputs/outputs, exit behavior and
  examples in a `doc/user/<Topic>.md` guide; runnable examples beat prose.
- Implementation mechanics (argument parsing, streaming, exit-code
  plumbing) belong in `doc/developer/`.
- Behavior claims about a CLI should come from running it, not from
  reading the option parser — cite the executed probe in `research/`
  when the behavior was non-obvious.
- Known defects in tooling go to `Improvements.md` with a receipt; do not
  document broken behavior as normal.

## Cross-repo pointers

When one repo documents a fact owned by another repo:

- Prefer linking to the owning repo's canonical guide
  (project-qualified path) over duplicating the content.
- Keep a small "see also" section with verified pointers — name the repo,
  the document and the relevant section.
- Cross-repo attribution of constants or shared conventions lives in
  that repo's `research/` attribution note when one exists.

## Research notes for environment-specific findings

Hazards, heuristics and sandbox/bwrap-specific behavior are
environment-specific: they belong in `research/<topic>.md` with the
environment recorded, while the *operational advice* that survives
generalization can be folded into the relevant `doc/` guide. Preserve
the distinction — a bwrap quirk is not a Scout contract.

## The `ScoutCoder:` comment convention

While coding, if you learn a reusable fact the documentation should have
covered, leave a `ScoutCoder:` comment at the triggering site. Promoted
comments are the raw material for doc improvements. Full convention:
[doc/user/Documentation.md](../../doc/user/Documentation.md) in this
repo, and the ScoutCoder README introduction.
