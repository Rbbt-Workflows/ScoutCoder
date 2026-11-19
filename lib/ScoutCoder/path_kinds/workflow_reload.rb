# Workflow-level reload helper (reload build, step 2).
#
# CONTRACT (pinned by the step-1 evidence probe — tmp/notes/reload-probe.md,
# probe source tmp/reload_probe/probe_source_take3.rb, Cortex
# reports/reload-step1-evidence.md; cite, do not re-derive):
#
#   * PURGE COMPOSITION: every $LOADED_FEATURES '.rb' entry whose
#     File.realpath(File.expand_path(entry)) falls under the
#     File.realpath'd target checkout root — INCLUDING the entrypoint
#     workflow.rb when it is a feature entry (child processes whose loader
#     does `require './workflow'` do cache it; require_workflow itself
#     evaluates the entrypoint with Kernel#load and never does).
#   * NORMALIZATION: File.realpath on BOTH sides. expand_path alone does
#     not resolve symlinks, so a symlinked/alias-spelled feature entry
#     (/home/... vs /bulk/... alias roots) would not collapse; realpath on
#     both sides does (verified against the live environment).
#   * RE-ENTRY: Workflow.require_workflow(<entrypoint>, update: true)
#     re-evaluates workflow.rb; once the lib features are purged, its
#     require_relative lines re-fire. Purge alone (no update:) already
#     makes a plain re-require re-execute a purged lib file.
#   * MEMO: re-evaluation returns the SAME workflow module object
#     (equal? true across loads, pinned), so ScoutCoder.target_workflow's
#     @@target_workflow memo survives reload correctly and is NEVER
#     touched here — the reloaded workflow IS the memoized object.
#     (Already-instantiated Step objects keep old definitions: the
#     documented Ruby reload caveat; consumers re-resolve through the
#     module.)
#
# INTENDED CALLERS (step 3 wired on the five promoting kinds; step 4 adds
# the explicit surface):
#   step 3: PROMOTION_POST_MOVE below — the promotion_post_move hook shared
#           by the promoting kinds (task, entity, entity_property,
#           python_task, test_file); the engine runs it after its own move
#           with args['promotion_target'] naming the absolute destination;
#   step 4: the explicit reload surface (knows a target workflow).
# Both derive a checkout root; the helper is call-site-agnostic.
#
# This module performs no writes of its own: reload re-evaluates existing
# source files (whose own side effects are theirs), and the report is a
# returned value, never a file.
#
# ScoutCoder: $LOADED_FEATURES entries are always absolute for project
# files in this environment (relative spellings are core-lib shims;
# Ruby canonicalizes relative requires to expanded absolute paths before
# caching), but realpath normalization is still REQUIRED for matching:
# the alias mount spellings (/home/... vs /bulk/...) differ lexically and
# realpath is what collapses them on both sides.
module ScoutCoder
  module WorkflowReload
    # Shared promotion_post_move hook (reload build, step 3).
    #
    # Engine contract (pinned live by the step-3 probes; engine path.rb
    # promote): the hook runs ONLY after the engine's own move succeeded,
    # receives (agent, path, location, args) where args carries
    # 'promotion_target' (absolute destination path), 'promotion_source_target'
    # and 'overwrite', and its return value is merged into the promote
    # result with the ENGINE keys winning on collision (path.rb:1732
    # `hook_result.merge(result)`), so this hook can add status keys but
    # can never falsify promoted/destination/promotion_target.
    #
    # POST-MOVE REPORT, NEVER A RAISE (reload-deferral change): the move
    # is already complete when the hook runs (the engine never rolls back
    # a completed move), so a raise after the move leaves the caller with
    # only a serialized exception envelope and NO destination/status —
    # exactly the field failure this hook now repairs. The hook therefore
    # RETURNS a report for every post-move outcome and raises ONLY when
    # it cannot construct a report at all (no promotion_target to anchor
    # on). reload_workflow! keeps normalizing internal failures to Scout
    # ParameterException, so nothing raw escapes the tool wrapper either
    # way.
    #
    # RESULT KEYS ADDED BY THIS HOOK (merged under the engine's
    # promoted/destination/promotion_target/promotion_source_target):
    #   'promotion_status' => 'succeeded' | 'deferred' | 'reload_failed'
    #   'post_move'        => 'workflow_reload' | 'workflow_reload_deferred'
    #   'reload'           => {'ok' => true, 'root', 'purged', 'mode'}
    #                        | {'ok' => false, 'error' => <original
    #                           diagnostic verbatim>, 'root' => <root
    #                           attempted, present only when one was
    #                           derivable — absent for a checkout-root
    #                           discovery failure>}
    #   'deferred_reload'  => the root to reload later (present only when
    #                         defer_reload was set)
    #
    # 'purged' is the COUNT of purged feature entries (the full list and
    # 'entrypoint' stay in reload_workflow!'s own report; the promote
    # receipt intentionally carries the compact form).
    #
    # DEFERRAL CHANNEL (ScoutCoder-only caller argument, zero engine
    # change): the engine merges caller keys into hook args verbatim and
    # validates nothing (verified live, path.rb:1725-1731), so
    # `defer_reload: true` on path_promote reaches the hook as
    # args['defer_reload']. The engine's path_promote tool schema declares
    # the flag (boolean, omittable, additionalProperties stays false), so
    # model-facing callers can emit it as well as programmatic ones.
    # Related promotions (new entity, then its
    # properties) defer every intermediate reload and issue exactly one
    # explicit reload afterwards, avoiding the reload of a
    # half-promoted set (the field failure: promoting the entity, the
    # automatic reload then evaluating the still-drafted property file
    # against an entity not yet supplying `property`). The boolean flag is truthy for true and the strings
    # 'true'/'t'/'yes'/'on' (case-insensitive); anything else is false.
    #
    # Root derivation: from args['promotion_target'] — walk up until a
    # directory containing workflow.rb (the promoted lib file sits under
    # <root>/lib/..., so the climb is short and deterministic). When the
    # climb finds NO workflow.rb the hook RETURNS 'reload_failed' with the
    # climb diagnostic in reload.error and no 'root' key (a fourth status is
    # deliberately not introduced: with the destination known, a caller's
    # recovery action — inspect/repair the destination, retry nothing — is
    # the same whether the reload failed in discovery or execution, and the
    # verbatim diagnostic carries the distinction). The ONLY raise left is
    # the missing-promotion_target arm: with no anchor there is no report to
    # construct. One shared lambda: every promoting kind registers the SAME
    # object, so the reload behavior is defined once here.
    PROMOTION_POST_MOVE = lambda do |_agent, _path, _location, args|
      raw = args['promotion_target'] || args[:promotion_target]
      raise ParameterException,
            'workflow reload after promote: no promotion_target in args' unless raw

      target = raw.to_s
      dir = File.dirname(File.expand_path(target))
      root = nil
      climb_error = nil
      loop do
        break if File.file?(File.join(dir, 'workflow.rb')) && (root = dir)
        parent = File.dirname(dir)
        if parent == dir
          # Checkout-root discovery failure: the destination IS known (the
          # engine passes promotion_target and merges its own promoted/
          # destination keys over any returned hash), so the caller must
          # still receive the completed-move receipt — report, never raise.
          climb_error = "workflow reload after promote: no workflow.rb found " \
                        "above #{target} (promoted outside any workflow checkout?)"
          break
        end
        dir = parent
      end

      defer_flag = args['defer_reload'] || args[:defer_reload]
      defer = [true, 'true', 't', 'yes', 'on'].include?(defer_flag.is_a?(String) ? defer_flag.downcase : defer_flag)
      return {'promotion_status' => 'deferred',
              'post_move' => 'workflow_reload_deferred',
              'reload' => {'ok' => false, 'deferred' => true},
              'deferred_reload' => root} if defer

      return {'promotion_status' => 'reload_failed',
              'post_move' => 'workflow_reload',
              'reload' => {'ok' => false, 'error' => climb_error}} if climb_error

      begin
        report = WorkflowReload.reload_workflow!(root: root)
        {'promotion_status' => 'succeeded',
         'post_move' => 'workflow_reload',
         'reload' => {'ok' => report['ok'], 'root' => report['root'],
                      'purged' => report['purged'].size, 'mode' => report['reload']}}
      rescue ParameterException => e
        # Post-move failure: the move is already complete; report it in
        # the result with the original diagnostic VERBATIM (the full
        # normalized message reload_workflow! produced) instead of the
        # bare exception envelope a raise would leave behind.
        {'promotion_status' => 'reload_failed',
         'post_move' => 'workflow_reload',
         'reload' => {'ok' => false, 'error' => e.message, 'root' => root}}
      end
    end.freeze

    class << self
      # Purge + full re-load of the workflow checkout rooted at `root`.
      #
      #   root: the workflow checkout root (a directory containing
      #         workflow.rb). Accepts any spelling (symlink/alias mounts
      #         resolve through realpath); nil/empty raises.
      #
      # Returns a report Hash:
      #   'ok'          true on success
      #   'root'        the realpath'd checkout root (String)
      #   'entrypoint'  the workflow.rb path re-evaluated (String)
      #   'purged'      the $LOADED_FEATURES entries removed, as spelled
      #                 (Array of Strings; [] when nothing was cached)
      #   'workflow'    the workflow module returned by require_workflow
      #   'reload'      'required' | 're-evaluated' — whether the
      #                 entrypoint was (re)loaded through require
      #                 (it had been a feature entry) or through
      #                 require_workflow's Kernel#load re-evaluation
      #   'error'       present only on failure (message String)
      #
      # Failure modes (loud, per the contract): a missing root directory or
      # a root without workflow.rb raises ParameterException — this helper
      # is only for real workflow checkouts. Reload itself is no-op-safe:
      # with nothing cached the purge list is [] and the reload still runs.
      def reload_workflow!(root: nil)
        root = root.to_s
        raise ParameterException,
              'WorkflowReload.reload_workflow! requires a workflow checkout root' if root.empty?

        unless File.directory?(root)
          raise ParameterException,
                "workflow checkout root does not exist or is not a directory: #{root}"
        end

        root_real = File.realpath(root)
        entrypoint = File.join(root_real, 'workflow.rb')
        unless File.file?(entrypoint)
          raise ParameterException,
                "no workflow.rb at the checkout root (#{root_real}); this helper only reloads real workflow checkouts"
        end

        purged = purge_features_under!(root_real)

        reload_mode = 're-evaluated'
        if purged.include?(entrypoint)
          # The entrypoint itself was a feature entry (child-loader
          # spelling `require './workflow'`): purge already un-cached it,
          # so a plain require re-executes it — the canonical full reload.
          require entrypoint
          reload_mode = 'required'
          # ScoutCoder: require_workflow's `silent: true` deletes the
          # workflow-name from Workflow.workflows before re-registering;
          # keep it — it prevents a duplicate entry per reload and prints
          # nothing in this environment either way (verified), while the
          # re-registration that immediately follows restores membership.
          workflow = Workflow.require_workflow(entrypoint, silent: true)
        else
          # ScoutCoder: same silent rationale as the branch above — see
          # the comment there and the README "Reload semantics" block.
          workflow = Workflow.require_workflow(entrypoint, silent: true, update: true)
        end

        {'ok' => true,
         'root' => root_real,
         'entrypoint' => entrypoint,
         'purged' => purged,
         'workflow' => workflow,
         'reload' => reload_mode}
      rescue ParameterException
        raise
      rescue StandardError, ScriptError => e
        # Never leak a raw exception through the callers this will hang off
        # (engine hooks surface non-Scout failures poorly — round-12
        # surprise 3); a reload failure is a parameter-class error.
        raise ParameterException, "WorkflowReload.reload_workflow! failed: #{e.class}: #{e.message}"
      end

      # Non-mutating twin of the purge: which feature entries WOULD be
      # purged for this root (same composition/normalization). Used by
      # tests and reports; also the single definition of the match rule.
      def features_under(root)
        root_real = File.realpath(root)
        $LOADED_FEATURES.select { |f| feature_under?(f, root_real) }
      end

      # Single match rule (pinned): realpath on BOTH sides, '.rb' files
      # only, feature must exist to realpath (a missing/deleted file no
      # longer matches; deleting its entry is then unnecessary but the
      # rule stays conservative).
      def feature_under?(feature, root_real)
        return false unless String === feature && feature.end_with?('.rb')
        real = begin
          File.realpath(File.expand_path(feature))
        rescue StandardError
          nil
        end
        !real.nil? && (real == root_real || real.start_with?(root_real + File::SEPARATOR))
      end

      private

      # Remove and return the feature entries under root_real (as spelled
      # in $LOADED_FEATURES). Mutates $LOADED_FEATURES in place.
      def purge_features_under!(root_real)
        purged = []
        $LOADED_FEATURES.delete_if do |feature|
          hit = feature_under?(feature, root_real)
          purged << feature if hit
          hit
        end
        purged
      end
    end
  end
end
