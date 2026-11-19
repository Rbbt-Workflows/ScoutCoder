# The `probe` path kind (round 12).
#
# Unsandboxed, ScoutCoder-only Ruby snippets for investigating the Scout
# framework itself. ONE location root `share/probes/` (the default and
# only location), name pattern [a-z][a-z0-9_]*, `.rb` suffix omitted from
# the virtual name. The engine-contract investigation (outcome C,
# tmp/notes/round12-engine-contract.md) proved:
#   * generic path_write NEVER consults the kind operation_table (DC-1)
#     and path_edit treats an override as a :content transform only,
#     with a :full-typed override crashing (DC-2) — so NO auto-run hook
#     inside generic write/edit; execution is delivered exclusively
#     through the custom operation below, the same channel the test_file kind uses;
#   * one-root, promote-less kinds register, list, resolve and validate
#     cleanly (question c, green) — path_promote is simply not installed.
#
# Capabilities: validate (syntax-only, NEVER executes) plus ONE custom
# operation `path_run` (:full handler, authorization: :read, mirroring
# the test_file kind's registration). NO smoke, NO promote. Generic
# read/list/move/rename/delete come from the engine with zero implicit
# execution; patch and test stay off.
#
# OPERATION NAME NOTE (round-12 ratification item): the round-12 design
# sketch called the custom operation `run`; the engine derives the
# model-facing tool name from the operation name
# (path_custom_tool_definition: ONE public tool per custom operation
# name), and the pin test requires the tool to be `path_run` — a bare
# `run` tool would also be a needlessly generic name on the agent
# surface. The operation is therefore named `path_run`.
#
# share/probes/ is NOT one of LiveWorkflow's four draft subdirs
# (tasks, helpers, entities, entity_properties — scout-gear
# lib/scout/workflow/live.rb SHARE_SUBDIRS), so nothing auto-loads the
# probes. Verified live in round 12, not assumed.
#
# TRUST BOUNDARY: the `path_run` operation executes trusted,
# agent-authored Ruby in a fresh UNSANDBOXED child (the invoking user's
# privileges). The `sandbox: true` kind flag governs which OPERATIONS the
# agent may call, not how the custom operation executes — exactly the
# test_file kind contract (README 'Trust boundaries').
require 'fileutils'

require_relative 'support'
require_relative '../probe_support'

module ScoutCoder
  def self.path_kind_probe_definition
    {
      'name' => 'probe',
      'description' =>
        'Unsandboxed ScoutCoder-only Ruby probe snippets for investigating the Scout framework ' \
        '(share/probes). Virtual paths are relative to the kind root: a bare name such as ' \
        'engine_probe, no .rb suffix and no physical prefix (share/probes/). Execution happens ' \
        'ONLY through the path_run tool; write/edit never auto-run. Probes are trusted code ' \
        'executed with caller authority.',

      'extension' => 'rb',
      'locations' => ['tmp'],
      'default_location' => 'tmp',

      'roots' => {
        'tmp' => Scout.share.probes
      },

      'sandbox' => true,

      # Generic CRUD from the engine (explicit for documentation value) +
      # validate. NO promote (one-root kind), NO smoke (validate is the
      # static check; path_run the executing check), NO patch, NO test.
      'capabilities' => {
        'read' => true, 'write' => true, 'edit' => true, 'list' => true,
        'move' => true, 'rename' => true, 'delete' => true,
        'validate' => true
      },

      # -----------------------------------------------------------------
      # validate: syntax ONLY. NEVER executes the file — no side effects
      # from validate, period. Proven by the side-effect canary tests
      # (valid AND invalid sources) in the round-12 regression suite:
      # a probe whose body writes a canary file must leave it absent
      # across every validate call.
      # -----------------------------------------------------------------
      'validate' => lambda do |agent, path, location, args|
        resolve_kind = args['kind'] || 'probe'
        resolve_kind = nil unless agent.respond_to?(:path_kind_definition) &&
                                 (agent.path_kind_definition(resolve_kind) rescue nil)
        target = agent.resolve_path(resolve_kind || 'probe', path, location)
        errors, warnings = [], []

        name = File.basename(path.to_s, '.*')
        if name !~ /\A[a-z][a-z0-9_]*\z/
          errors << "probe name must match [a-z][a-z0-9_]* (got #{name.inspect})"
        end

        unless File.file?(target.to_s)
          return {'ok' => false, 'kind' => 'probe', 'op' => 'validate',
                  'path' => path, 'location' => location,
                  'reasons' => ["target does not exist or is not a file: #{target}"]}
        end

        source = File.read(target.to_s)
        syntax = ScoutCoder::ProbeSupport.syntax_error_in(source)
        errors << "ruby syntax error: #{syntax}" if syntax

        if errors.empty? && source.strip.empty?
          errors << 'probe source must be non-empty'
        end

        warnings << 'no documentation comment (convention: probes open with a # comment stating what they investigate)' if source !~ /\A\s*#/

        {'ok' => errors.empty?, 'kind' => 'probe', 'op' => 'validate',
         'path' => path, 'location' => location,
         'reasons' => errors, 'warnings' => warnings}
      end,

      # -----------------------------------------------------------------
      # ONE custom operation: `path_run`. The outcome-C channel — custom
      # operations DO return their payload verbatim (a3 evidence), unlike
      # write/edit overrides. :full handler + authorization: :read, the
      # exact test_file-kind registration shape. When `source` is supplied the
      # implementation owns the write (handler-owns-the-write shape the
      # engine documents for custom operations): save first, syntax-check,
      # then execute, reporting saved/syntax/execution independently.
      # -----------------------------------------------------------------
      'operations' => {
        'path_run' => {
          'description' => ScoutCoder::PATH_RUN_DESCRIPTION,
          'parameters' => ScoutCoder::PATH_RUN_PARAMETERS,
          'implementation' => lambda do |agent, target, args|
            # Union contract: scope belongs to kind=test_file. Reject it
            # BEFORE any write or execution — silently ignoring it would
            # let a caller believe a tree ran. (round-14 decision)
            if args['scope']
              raise ParameterException,
                    'path_run (kind=probe): scope is not applicable to the probe kind ' \
                    '(a probe is one snippet, never a tree); scope belongs to kind=test_file. '
            end
            saved = Thread.current[:scoutcoder_probe_kind]
            begin
              Thread.current[:scoutcoder_probe_kind] = args['kind'] || saved
              ScoutCoder::ProbeSupport.dispatch(agent, target, args)
            ensure
              Thread.current[:scoutcoder_probe_kind] = saved
            end
          end,
          'authorization' => :read,
          'type' => :full
        }
      }

      # NO 'promotion_destination': the kind is promote-less by design
      # (one root; outcome-C question c). Neither the promote capability
      # nor a destination is declared, and the engine installs no
      # path_promote tool for the kind.
    }.freeze
  end

  # Registration-time snapshot for THIS process (the single-incorporation
  # flow), merged into ScoutCoder::PATH_KINDS by the aggregator.
  PATH_KIND_PROBE_DEFINITION = path_kind_probe_definition.freeze
end
