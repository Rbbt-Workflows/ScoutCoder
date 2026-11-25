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

Use the full Ruby constant name as one virtual path component. Each component
of the constant matches `[A-Z][A-Za-z0-9]*`, including acronyms such as
`TF`. Property names use snake_case (`[a-z][a-z0-9_]*`).

| Ruby module | Entity path | Property path |
|---|---|---|
| `TF` | `TF` | `TF/label` |
| `AGS::TF` | `AGS::TF` | `AGS::TF/label` |

For `AGS::TF`, the entity file is `share/entities/AGS::TF.rb`. Define the
namespace and entity together so the draft can load in a fresh Ruby process:

```ruby
module AGS
  module TF
    extend Entity
  end
end
```

The property file `share/entity_properties/AGS::TF/label.rb` can then
reopen `module ::AGS::TF`. Ruby's compact declaration requires the parent
namespace to exist when the file loads. A leading `::` is Ruby source syntax.
Start the virtual path with the first namespace component.

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

The entity file declares the module named by its path and calls
`extend Entity` or `extend EntityWorkflow` inside that module. A property
draft reopens the same module and declares a property there. A typeless
`property :plain do` dispatches as `:both`.

## Generated entity/property file shapes

The generated form of a complete entity file looks like this (the
identifiers call is included only when an identifier TSV exists beside it
under `share/entity/<entity>.identifiers.tsv`):

```ruby
# share/entities/DemoWidget.rb — the COMPLETE file a draft must be.
module DemoWidget
  extend EntityWorkflow
  add_identifiers Path.setup(File.expand_path('../entity/DemoWidget.identifiers.tsv', __dir__))
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

Use `path_run` with `kind: "probe"` to exercise a draft in a fresh
Ruby process that loads the owning checkout. After promoting and wiring
the definitions, **force a reload of that checkout in the runtime serving
the consumer**. For Research, verify that Semantics lists the full entity
type and that `entity_property` returns the expected value for a known
identifier. A reload performed only by a separate ScoutCoder process
updates its own registry. Follow [the reload procedure](PathKinds.md#force-the-reload-and-verify-consumer-access).

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
source-path fields. ScoutCoder looks for the full module name in its
`share/entities/` drafts and the corresponding `share/entity_properties/`
directory. For example, `AGS::TF` and `Other::TF` have separate source
entries. Effective dispatch
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
