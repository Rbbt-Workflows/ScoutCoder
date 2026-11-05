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
    # result under 'post_move'. A raised exception is reported as the
    # promote result's 'exception' but the MOVE STANDS (the engine never
    # rolls back a completed move); a refused promote never invokes the
    # hook. The hook is never the writer: it purges and reloads ONLY.
    #
    # Root derivation: from args['promotion_target'] — walk up until a
    # directory containing workflow.rb (the promoted lib file sits under
    # <root>/lib/..., so the climb is short and deterministic). Fail LOUDLY
    # (ParameterException) if no checkout root is derivable; never skip
    # silently. One shared lambda: every promoting kind registers the SAME
    # object, so the reload behavior is defined once here.
    PROMOTION_POST_MOVE = lambda do |_agent, _path, _location, args|
      target = args['promotion_target'] || args[:promotion_target]
      raise ParameterException,
            'workflow reload after promote: no promotion_target in args' unless target

      dir = File.dirname(File.expand_path(target.to_s))
      root = nil
      loop do
        break if File.file?(File.join(dir, 'workflow.rb')) && (root = dir)
        parent = File.dirname(dir)
        raise ParameterException,
              "workflow reload after promote: no workflow.rb found above #{target} " \
              '(promoted outside any workflow checkout?)' if parent == dir
        dir = parent
      end

      report = WorkflowReload.reload_workflow!(root: root)
      {'post_move' => 'workflow_reload',
       'reload' => {'ok' => report['ok'], 'root' => report['root'],
                    'purged' => report['purged'].size, 'mode' => report['reload']}}
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
      rescue StandardError => e
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
