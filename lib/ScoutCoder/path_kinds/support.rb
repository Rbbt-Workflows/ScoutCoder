# Shared support for the ScoutCoder path kinds (round 9 split).
#
# Holds everything that is NOT a kind definition and NOT the shared
# test-file-finding authority (see test_file.rb): the dynamic
# current-workflow anchor (target_workflow / target_workflow_name) and the
# structural checkout-root anchor PATH_KIND_ROOT.
#
# The anchors live here (not in a kind file) because ALL kind files use
# them (descriptions, project roots, fresh-process smoke chdir), and the
# engine may load path_kinds.rb more than once per process: the memoized
# @@target_workflow survives a re-require, and PATH_KIND_ROOT is
# re-assigned to the same value under Kernel#load, so both load paths are
# safe.
#
# ScoutCoder: the Scout convention for a workflow anchoring its own
# directory is Path.caller_lib_dir (scout-gear lib/scout/workflow.rb,
# Workflow.extended), which walks up from the calling file until it finds
# a directory containing a marker entry (lib, bin or README.md). For this
# checkout it resolves to the same root, but it depends on marker files
# rather than on the file layout, so the structural __dir__ anchor is
# preferred here; there is no documented one-call helper for "checkout
# root of the currently loading file" that does not depend on markers.
# NOTE: the pre-split file lived at lib/ScoutCoder/path_kinds.rb (root two
# levels up); this file is one level deeper, so the root is anchored off
# the AGGREGATOR's directory, which keeps the same resolved root.
module ScoutCoder
  def self.target_workflow
    # The project anchor is resolved ONCE, from the directory the process
    # loads from (the workflow.rb gate); afterwards the memo is
    # authoritative. A later Dir.chdir (agent tool loops, sandboxed hook
    # tests) must not flip the paired-test conventions to UnknownWorkflow
    # mid-process: the workflow identity is a process-stable fact.
    return @@target_workflow if defined?(@@target_workflow) && @@target_workflow
    return nil unless File.exist?('./workflow.rb')
    @@target_workflow = Workflow.require_workflow('./workflow.rb', silent: true)
  end

  def self.target_workflow_name
    return "UnknownWorkflow" if target_workflow.nil?
    @@target_workflow_name ||= target_workflow.name
  end

  # Checkout root anchored structurally: the AGGREGATOR lives at
  # <checkout>/lib/<workflow>/path_kinds.rb, two levels up from there.
  PATH_KIND_ROOT = File.expand_path('../..', File.join(__dir__, '..'))
end
