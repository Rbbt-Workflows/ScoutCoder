# Path kinds for the scout-ai agent path engine (round 5; split into a
# five-file structure in round 9).
#
# AGGREGATOR ROLE: this file defines ScoutCoder::PATH_KINDS, the
# workflow-scoped constant the engine consumes on WHOLE-WORKFLOW
# incorporation (integrate_workflow_path_kinds in scout-ai
# lib/scout/llm/agent/path/workflow_kinds.rb, from a whole-workflow `tool:
# <Workflow>` chat line only). The three kind definitions live in separate
# files under lib/ScoutCoder/path_kinds/; this file only loads them in a
# deterministic order and merges their constants into one Hash.
#
# Structure (round 9 build, complete):
#   lib/ScoutCoder/path_kinds.rb            this aggregator
#   lib/ScoutCoder/path_kinds/support.rb    dynamic workflow anchor + PATH_KIND_ROOT
#   lib/ScoutCoder/path_kinds/test_file.rb  `test_file` kind + PathKindTestFiles authority
#   lib/ScoutCoder/path_kinds/task.rb       the `task` kind
#   lib/ScoutCoder/path_kinds/entity.rb     the `entity` kind
#   lib/ScoutCoder/path_kinds/entity_property.rb  the `entity_property` kind
#
# Behavior is preserved exactly from the pre-split single file: every
# handler body (validate/test/smoke/resolve/promote hooks) moved as-is, and
# the shared test-file-finding helpers moved once into
# ScoutCoder::PathKindTestFiles, which now lives in its final home
# path_kinds/test_file.rb (round 9 build superseded test_file_paths.rb,
# deleted in the same change).
#
# Whole-workflow incorporation must keep working for BOTH shapes the engine
# accepts (Hash name=>def, or Array of definition Hashes with a "name"
# key): the merged PATH_KINDS here is a Hash keyed by kind name, which is
# the shape the engine normalizes; nothing here needs the Array form.
#
# Loading contract: the engine (and workflow.rb's require gate) may load
# this file MORE THAN ONCE per process. require_relative is idempotent for
# re-require, and every file re-evaluated via Kernel#load tolerates
# re-declaration (constant re-assignment of equal values, task re-assign,
# helper re-definition), so both load paths are safe. Load order is fixed:
# support (anchor) -> test_file (kind + shared helpers) -> task -> entity
# -> entity_property, mirroring the pre-split single-file order (helpers,
# then PATH_KINDS entries in the same sequence).
#
# Virtual paths for entity_property are NESTED (<entity>/<property>.rb) so the
# engine's path-preserving declarative promotion covers the whole kind with one
# destination (round-7 decision 2). Identifier TSVs (share/entity/*.tsv) are
# deliberately OUT of scope (decision 3). Project-side entity/property files are
# NOT loaded by workflow.rb today: promotion is a pure engine-controlled file
# move and lib-side wiring is a separate deliberate workflow.rb change
# (decision 6). Engine pin for round 7: path.rb md5 e50f4c12faa95d1f142bc81737210c97
# (scout-ai b504275).

require 'scout/workflow'
require 'fileutils'
require 'open3'
require 'rbconfig'

require_relative 'path_kinds/support'
require_relative 'path_kinds/test_file'
require_relative 'path_kinds/task'
require_relative 'path_kinds/entity'
require_relative 'path_kinds/entity_property'

module ScoutCoder
  # The shared test-file-finding helpers (formerly ScoutCoder.path_kind_*
  # methods in the pre-split single file) keep their historical call sites
  # — the kind files call them as ScoutCoder.path_kind_* — so ScoutCoder
  # extends the shared module instead of every kind file re-aliasing.
  # `module_function` methods copy private-singleton semantics when
  # extended, which would break the kind files' explicit
  # ScoutCoder.path_kind_* receivers, so the shared module declares
  # module_function for internal self-calls AND ScoutCoder aliases each
  # helper publicly here (one place, in the aggregator).
  extend PathKindTestFiles

  class << self
    PathKindTestFiles.private_instance_methods(false).each do |m|
      next unless m.to_s.start_with?('path_kind_')
      define_method(m, PathKindTestFiles.instance_method(m))
      public m
    end
  end

  # Whole-workflow PATH_KINDS constant: keys ARE the kind names, so a
  # missing or typo'd "name" key cannot silently mis-register. Built by
  # merging each kind file's PATH_KIND_<KIND>_DEFINITION in fixed order;
  # the values are shared by reference (the engine deep-copies at
  # registration anyway).
  PATH_KINDS = {
    'task' => PATH_KIND_TASK_DEFINITION,
    'entity' => PATH_KIND_ENTITY_DEFINITION,
    'entity_property' => PATH_KIND_ENTITY_PROPERTY_DEFINITION,
    'test_file' => PATH_KIND_TEST_FILE_DEFINITION
  }.freeze
end
