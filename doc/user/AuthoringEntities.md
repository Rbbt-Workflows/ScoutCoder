# Authoring entities and Python tasks

Entity modules and their properties are authored as DRAFTS through the
`entity` and `entity_property` path kinds: `path_write kind=entity
path=<name>` writes `share/entities/<name>.rb` and `path_write
kind=entity_property path=<entity>/<property>` writes
`share/entity_properties/<entity>/<property>.rb`. Scout-gear's
`LiveWorkflow` loads entity drafts before property drafts on every workflow
reload; the shipped built-in entity tree would live under
`lib/<workflow>/entity/`, which **does not exist in this checkout**
(corrected from earlier text that said it "exists but is empty").

Entity-TYPE names are CamelCase: they must match `[A-Z][A-Za-z0-9]*` (e.g.
`DemoWidget`, or the all-caps acronym `TF`); a name such as `DemoWidget`
maps to the top-level `::DemoWidget` module. Property names stay
snake_case (`[a-z][a-z0-9_]*`).

LEGACY ACCEPTANCE: an old-pattern snake_case entity name
(`[a-z][a-z0-9_]*`, e.g. `demo_widget`) still validates, with a warning
that names both spellings; the virtual path keeps the user's spelling
(`share/entities/demo_widget.rb` stays `demo_widget`), and the module
constant is the Rule-B camelization — `demo_widget`.split('_').
map(&:capitalize).join → `DemoWidget`. Two cases are HARD errors: a snake
name whose Rule-B constant collides with the constant of a coexisting
CamelCase draft (`demo_widget.rb` + `DemoWidget.rb` both → `DemoWidget`),
and two snake names whose Rule-B constants collide (`a_b` + `a__b` both →
`AB`). Ratified by the decision artifact
`var/cortex/artifacts/reports/entity-case-convention-decision.md`
(corrected path; formerly cited as bare `reports/…`).

The entity base is the `extend Entity` (or `extend EntityWorkflow`) line
INSIDE the entity file — a hand-authored draft carries its own `module`
wrapper and its own extend line, because `Kernel#load` evaluates the file
at top level; `path_validate` (`entity` kind) checks exactly this shape:
the top-level module must match `constant_name` of the file name
(`DemoWidget.rb` → `module DemoWidget`, and `TF.rb` → `module TF`, optional
leading `::` — a legacy `demo_widget.rb` must declare `module DemoWidget`,
the Rule-B constant) and must contain the extend line. An `entity_property`
draft conversely must NOT carry an extend line (the entity file owns the
extend) and must declare `property :name => :type do ... end`;
`path_validate` checks that too; its entity segment follows the same name
rules (CamelCase canonical, legacy snake accepted with the warning). A
typeless `property :plain do` is valid and dispatches as `:both`.

## Generated entity/property file shapes

The generated form of a complete entity file looks like this (the
identifiers call is included only when an identifier TSV exists beside it
under `share/entity/<entity>.identifiers.tsv`):

```ruby
# share/entities/DemoWidget.rb — the COMPLETE file a draft must be.
module DemoWidget
  extend EntityWorkflow
  add_identifiers Path.setup(File.expand_path('../../entity/DemoWidget.identifiers.tsv', __dir__))
  annotation :organism
end
```

A property draft is the property declaration plus body, wrapped in the SAME
entity module:

```ruby
# share/entity_properties/DemoWidget/label.rb
module DemoWidget
  property :label => :single do |prefix, suffix|
    "#{prefix}#{self}#{suffix}"
  end
end
```

## Authoring formats (complete file bodies)

These examples show the file shapes the path kinds and validators expect;
they are complete file bodies, not generator inputs.

- An entity draft is a complete module file: `module <Entity>` wrapper, the
  `extend Entity` / `extend EntityWorkflow` line, then annotations and
  helper declarations. Example:

  ```ruby
  module DemoWidget
    extend EntityWorkflow
    annotation :organism
  end
  ```

  The acronym case (the `TF` example that motivated the CamelCase switch):
  a short all-caps type stays all-caps, and the module name is identical to
  the file name:

  ```ruby
  # share/entities/TF.rb
  module TF
    extend Entity
  end
  ```

- A property draft is a `property :<name> => :<dispatch_type> do
  |args...| ... end` declaration and executable body, wrapped in the
  existing entity module:

  ```ruby
  property :hello => :single do |prefix, suffix|
    "#{prefix}#{self}#{suffix}"
  end
  ```

- For a Python task draft, author the function definitions and explicit
  `scout.task(function)` registration; the file needs its own top-level
  `import scout` (after a module docstring and `__future__` imports when
  present). It supplies no function or task declaration. For example:

  ```python
  import scout

  def greet(name: str = "World") -> str:
      return f"Hello, {name}!"

  scout.task(greet)
  ```

## Identifier TSVs

Identifier TSVs live at `share/entity/<entity>.identifiers.tsv`. One must
be non-empty and have a header accepted by `TSV.parse_header` naming the
identifier formats it maps (for example, `#ID,Name`; identifier-file
conventions are documented once in scout-gear
`doc/user/WorkingWithEntities.md` § "Format and identifier translation").
The TSV header fields name its identifier formats. The `add_identifiers`
path is constructed relative to the entity definition file, so registration
does not depend on the process's current working directory. Identifier
files are resource data, never loaded as Ruby, and a draft should not
overwrite an existing one casually.

The entity definition registers that path with `add_identifiers` at load
time. Draft files live under `share/entities/` and
`share/entity_properties/`; the built-in module/property loader for
`lib/<workflow>/entity/` is a separate convention. Do not relocate drafts
to the built-in tree expecting the LiveWorkflow loader to discover them.

## Production versus development dispatch

There are two distinct surfaces for dispatching a property. A production
dispatch surface — such as Semantics' `entity_property` task — dispatches
what its own process loaded; it deliberately does NOT reload drafts defined
after its process started, so a fresh `share/` draft is invisible to it
until that process reloads the workflow. That is expected behavior, not a
defect. Development verification of a fresh draft therefore goes through
`path_run` with `kind: "probe"` (see
[path_run](PathKinds.md#path_run-one-operation-two-runnable-kinds)): its
fresh child preloads the owning checkout's `workflow.rb`, so LiveWorkflow
live-loads the current `share/` drafts and the probe dispatches the
property exactly as a newly-loaded process would.

## Inspecting entities with list_entities

Use `list_entities` to inspect every entity module known to the process:

```ruby
entities = ScoutCoder.job(:list_entities).run
```

With no inputs the task returns one record per module that has extended
`Entity` in the current process, deduplicated: framework modules such as
`AssociationItem` appear alongside any ScoutCoder entities, because the
default enumeration walks the append-only `Entity::MODULES` registry (a
workflow reload re-extends the same module object, which would otherwise
duplicate rows). Its sorted results include each entity's name, module,
detected base kind, annotations, formats, identifier files, registered
properties, effective dispatch, persistence flags, plus inferred
source-path fields. Source paths are inferred from the conventional
`lib/<workflow>/entity/` layout, not tracked from Ruby's runtime source
locations, so framework modules report no checkout paths. Effective dispatch
is inferred from generated method names, so it cannot distinguish the
original `:single2array` alias from `:single`, or `:array2single` from
`:array`. The underlying helper also accepts an explicit module scope, which
restricts the listing to that module's own entity constants; the task itself
exposes no input for it.

## Built-in entity tree note

Built-in entity definitions and property files would live under
`lib/<workflow>/entity/`; that tree does not exist in the checkout today and
no loader reads it. Identifier TSV files remain under `share/entity/`; they
are resource data registered by the entity definition's `add_identifiers`
call. Entity and property drafts are created through the `entity` /
`entity_property` path kinds and loaded live by Scout-gear's `LiveWorkflow`
under `share/entities/` and `share/entity_properties/`. These are separate
loading conventions; do not relocate drafts to the built-in tree expecting
the LiveWorkflow loader to discover them.

The four property dispatch types (`:single`, `:array`, `:multiple`,
`:both`), their receiver and return shapes and their caching traps are
detailed in [doc/developer/PropertyDispatch.md](../developer/PropertyDispatch.md).
