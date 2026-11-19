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

  # ---------------------------------------------------------------------
  # Round-14 `path_run` union contract
  # (tmp/path-run-round14/decision-record.json, receipts 05-07):
  # the probe and test_file kinds register the SAME custom-operation name
  # `path_run` with an IDENTICAL, kind-neutral parameter contract
  # {source, scope, timeout_seconds} and NO declared defaults (a declared
  # default on either side makes the engine's parameter-contract merge
  # fail with a ParameterException naming both kinds — receipt 05_a).
  # The engine installs exactly ONE path_run tool; its kind enum carries
  # every registering kind; per-property descriptions come from the FIRST
  # registrant and the op description from the LAST, so BOTH kinds must
  # carry byte-identical declarations — guaranteed by sharing these two
  # constants. `kind`, `path` and `location` are engine-reserved and are
  # NOT re-declared here. Each kind's handler rejects the other kind's
  # parameter BEFORE any execution (probe rejects scope; test_file rejects
  # source), so a caller can never believe an inapplicable option took
  # effect. Omitting timeout_seconds reaches the handler as nil and the
  # runner's own default applies (receipt 07: no engine-injected default).
  PATH_RUN_DESCRIPTION =
    'Run one path-kind artifact in a fresh process. kind=test_file: run Scout test files — ' \
    'one file (scope=file), every file under a path prefix (scope=directory), or the entire ' \
    'suite (scope=suite), each in a fresh Ruby process that loads the workflow.rb of the ' \
    'project checkout that owns the test file. Virtual test paths are tier-prefixed and ' \
    'relative to the test_file kind root (task/greet_user, integration/round_trip, "." for ' \
    'the suite root), with no .rb suffix and no physical prefix. kind=probe: run one probe ' \
    'Ruby snippet in a fresh UNSANDBOXED child that preloads the owning checkout workflow.rb; ' \
    'with source the probe is saved first (never reverted on failure), syntax-checked, then ' \
    'executed — saved/syntax/execution are independent outcomes — and without source the ' \
    'saved probe is re-executed. source applies only to kind=probe and scope only to ' \
    'kind=test_file; each kind rejects the other parameter before executing. timeout_seconds ' \
    'is optional (1..3600; default 120, or 300 for suite scope). Probes are trusted code ' \
    'executed with caller authority: not a sandbox boundary.'

  PATH_RUN_PARAMETERS = {
    'properties' => {
      'source' => {'type' => 'string',
                   'description' => 'OPTIONAL complete probe source (kind=probe only): when given the probe is written/overwritten, syntax-checked and executed in one call (create-and-run); a syntax failure leaves the source saved but unexecuted. Rejected by kind=test_file.'},
      'scope' => {'type' => 'string', 'enum' => %w[file directory suite],
                  'description' => 'OPTIONAL test-file scope (kind=test_file only; default file). file: run the single test file at path. directory: run every test file under the path prefix. suite: run every discovered test file in all locations (path is the root selector; use "."). Rejected by kind=probe.'},
      'timeout_seconds' => {'type' => 'integer',
                            'description' => 'OPTIONAL timeout in seconds, 1..3600 (default 120; 300 for test_file suite scope). Out-of-range or non-integer values are rejected before any child process spawns.'}
    }
  }.freeze
end
