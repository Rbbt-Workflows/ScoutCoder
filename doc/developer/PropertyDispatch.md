# Property dispatch

The four property types — `:single`, `:array`, `:multiple`, `:both` (the
default when the declaration is a bare `property :name do`) — decide both
what the block receives and what the caller gets back. Scout-gear authority:
`doc/user/WorkingWithEntities.md` § "Properties" (the two up-front behaviors)
and `doc/developer/EntitySystem.md` § "Property dispatch" (the full matrix,
including the single-receiver return cell).

**Line citations in this document are pinned to scout-gear 10.13.1**
(`lib/scout/entity/property.rb`; re-verified against the installed gem for
this extraction — the former README cited the same numbers without a
version pin).

| type x receiver | block input (self) | return shape |
|---|---|---|
| `:single`, single entity | the entity itself, once | block result |
| `:single`, list receiver | each member, once per member | Array of per-member results |
| `:array`, list receiver | the whole list, once | block result, unchanged |
| `:array`, single entity | one-element array (`make_array`, property.rb:141) | **collapsed**: `Array === res ? res[0] : res[self]` (property.rb:142) |
| `:multiple`, list receiver | the whole list, once | Array: `responses.values_at(*self)` (property.rb:98) |
| `:multiple`, single entity | one-element array (`make_array`) | collapsed `res[0]`/`res[self]`, like `:array` |
| `:both`, single entity | the entity as-is | block result |
| `:both`, list receiver | the whole list, once (no wrapper; property.rb:114) | block result |

Verified 10.13.1 anchors for the cells above: `:single`/`:single2array` →
`Entity::Property.single_method`, `:array`/`:array2single` → `array_method`,
`:multiple` → `multi_method` (property.rb:50-56, alias pairs at 51-54);
`responses.values_at(*self)` at property.rb:98; the per-item `persist` wrap
around the list real method at property.rb:108-110; `return if type ==
:both` at property.rb:114; the contained/`make_array` collapse at
property.rb:138-145 (141: `res = self.make_array.send(...)`, 142:
`Array === res ? res[0] : res[self]`); `Entity::Property.persist` /
`Entity#persist` at property.rb:149-154 with `Entity.entity_property_cache`
defaulting to `var/entity_property` (property.rb:6-7).

## Two traps the probe evidence confirmed

(Cortex `research/w3-w5-verified-facts.md`)

- A single receiver on an `:array`/`:multiple` property **wraps the block's
  self into a one-element array but collapses the return value to its first
  element** (property.rb:141-142). The "cast into an array" intuition is right
  only about the block receiver; the return is `res[0]`. Use
  `mod.setup(id).make_array` to get the full Array result instead.
- `:multiple`'s generated method probes the per-item cache first and computes
  only missing members (property.rb:74-96), but **the cache layer itself is
  `Entity.persist`** (property.rb:149-154, dir `var/entity_property`), which
  wraps every arity's real method (property.rb:108-110) — and it caches ONLY
  when `persist` is declared; otherwise options are `{persist: false}` and
  nothing is persisted. `:single2array`/`:array2single` are aliases of
  `:single`/`:array` (property.rb:51-54).

## Generator and inference behavior of the entity path kinds

`path_write kind=entity_property` records NO arity metadata: the generator
`EntityDefinitionSupport.property_source` (`lib/ScoutCoder/tasks/entity_tools.rb`,
method at L292) only wraps the authored text, the property type lives inside
the `property :x => :type` declaration, and `effective_dispatch`
(`entity_tools.rb`, method at L394) later INFERS the type from the
registered accessor. The draft carries the type; nothing else records it.

## Loader-contract note (development side of entity authoring)

Scout-gear's `LiveWorkflow` loader loads entity drafts before recursively
loading property drafts in sorted order (see
[Layout.md](Layout.md) and [LiveWorkflow.md](LiveWorkflow.md) for the
combined order). Entity-before-property ordering is a loader contract: a
property file whose entity module has not been loaded fails loudly at load
time, never silently. `path_validate` checks names, Ruby syntax, and the
shape declarations; it does not prove the semantics of the Ruby code. Since
the source executes during workflow loading and reload, treat it as trusted
code, not sandboxed input.
