# The `test_file` path kind (built in round 9 from
# research/test-file-path-kind-guide.md).
#
# ONE kind owns the unit/integration test files of the current workflow:
#   tmp     -> share/test/**           (drafts' paired tests; never loaded
#                                      by LiveWorkflow)
#   project -> test/<workflow>/**      (promoted copies, `test_` prefixed)
#
# The virtual spelling is the tmp-side path below `share/test` WITHOUT the
# `.rb` extension: `task/greet_user`, `entity/demo_widget`,
# `entity_property/demo_widget/tag_palette`, `helper/join_parts`,
# `integration/round_trip`. The two sides name the same logical test
# differently (no `test_` prefix vs prefixed, `task/` vs `tasks/`, nested vs
# flattened property names), so the `resolve` hook owns the mapping; the
# engine skips its default root-joining and extension handling when a kind
# declares `resolve` (path.rb#resolve_path), so every operation flows
# through it.
#
# UNIT/INTEGRATION CLASSIFICATION: the first virtual segment `integration`
# marks an integration test; any other first segment (`task`, `entity`,
# `entity_property`, `helper`) marks a unit test. Both classes are ordinary
# resources of the same kind with identical capabilities.
#
# `patch` is off (whole-file authored sources, like the three source kinds);
# `test` is off (nothing may be named `test`; the engine's built-in `test`
# operation is scheduled for removal and this kind must not depend on it).
# `smoke` is off (round 10): test_file is checked statically by `validate`
# and executed by the custom operation `run_test`, which reports
# `executed`/`passed` and the exit status separately — the old
# ran-OK-even-if-failing smoke verdict is redundant. The runner is declared
# under `operations` (registering it establishes support implicitly), backed
# by the shared `ScoutCoder::TestFileSupport` module.
#
# This file is also the FINAL HOME of the shared test-file mapping
# authority `ScoutCoder::PathKindTestFiles` (moved here from
# path_kinds/test_file_paths.rb, deleted in the same change; the module
# keeps its historical name for call-site stability: the resolver, list
# and validate hooks call ScoutCoder.path_kind_* receivers via the
# aggregator's alias pass). The header of the old file mandated exactly
# this adoption rather than a fourth fork. Round 10 removed the
# pre-round-9 per-tier forward helpers (zero callers), the smoke
# capability, and (step 6) the source-kind paired-test relocation hooks.
require 'fileutils'
require 'open3'
require 'rbconfig'

require_relative 'support'
require_relative '../test_file_support'

module ScoutCoder
  # -------------------------------------------------------------------------
  # Shared paired-test location authority (superseded here from
  # path_kinds/test_file_paths.rb; module name kept).
  #
  # Every project-side path is built from ScoutCoder.target_workflow_name
  # — the dynamic current-workflow anchor — so no workflow-name literal
  # appears in this module. Roots are Scout path declarations resolved
  # with `.find(:current)`: never bare `.find` on Scout.root[...] /
  # Scout.lib[...], which would resolve to the USER STORE (~/.scout/...)
  # from a foreign checkout (round-8 verified trap).
  # -------------------------------------------------------------------------
  module PathKindTestFiles
    # (Round 10: SMOKE_TIMEOUT is removed with the smoke handler. Per-run
    # timeouts come from TestFileSupport::FILE_TIMEOUT /
    # DIRECTORY_TIMEOUT / SUITE_TIMEOUT through the run_test operation.)
    module_function

    # First `task :name` (or `task 'name'`) declaration in a task source.
    def path_kind_task_name_in(source)
      source[/^\s*task\s+:(\w+)/, 1] || source[/^\s*task\s+'(\w+)'/, 1]
    end

    # (Round 10: the five per-tier paired-test helpers are removed:
    # path_kind_test_file, path_kind_entity_test_file,
    # path_kind_entity_property_test_file, path_kind_helper_test_file and
    # path_kind_integration_test_file. They were the pre-round-9 forward
    # mapping superseded by `path_kind_resolve_test_file` / the round-9
    # inverse `path_kind_virtual_path_for`; they had ZERO callers in lib/,
    # share/, workflow.rb or the regression suite (grep-verified), and the
    # integration one contradicted the resolver on the project-side name
    # (baseline defect D6). The source kinds' paired-test relocation hooks
    # were themselves removed in round-10 step 6; nothing builds those
    # destinations anymore — the advisory mapping below documents the
    # convention for agents.)

    # Entity-type name -> top-level module constant. CamelCase entity
    # names (canonical; decision artifact
    # reports/entity-case-convention-decision.md) pass through UNCHANGED;
    # legacy snake_case names camelise by Rule B, following
    # EntityDefinitionSupport#constant_name (entity_tools.rb). NOTE:
    # Misc.camel_case must never be used here — it splits on digit runs
    # and mangles hex/digit-bearing names (probe evidence in the decision
    # artifact: Rule B matches 18/18 legacy draft modules, Misc.camel_case
    # 1/18).
    def path_kind_entity_module_name(entity)
      ScoutCoder::EntityDefinitionSupport.constant_name(entity)
    end

    # Top-level module names declared by a piece of Ruby source, in order.
    # Used for the shape checks: an entity file declares exactly one
    # top-level module; a property file declares the entity's module.
    # An optional leading "::" is accepted ("module ::Gene" is legal Ruby
    # at top level under Kernel#load and still names the bare constant),
    # so only the BARE name is captured (fix 4, session main.chat#44-48).
    def path_kind_top_level_modules(source)
      source.scan(/^module\s+(?:::)?([A-Z]\w*)\s*$/).flatten
    end

    # First top-level module name declared by the source, or nil.
    def path_kind_top_level_module(source)
      path_kind_top_level_modules(source).first
    end

    # (entity / entity_property per-tier helpers removed in round 10 — see
    # the note above the task-tier removal for the shared rationale.)

    # ----- round-9 additions: helper / integration tiers + inverse mapping -----
    # (helper / integration per-tier helpers removed in round 10 — see the
    # note above the task-tier removal for the shared rationale; the
    # integration one was baseline defect D6's contradicting mapping.)

    # ------------------------------------------------------------------
    # Round-10 step 4 — the single forward/inverse MAPPING AUTHORITY.
    # One place maps between virtual paths and relative physical paths,
    # for BOTH locations and every tier; the resolver, the list hook's
    # inverse and the source-kind promotion hooks all call THESE methods
    # (the resolver routes its forward leg through
    # path_kind_map_forward_segments; the list hook's inverse IS
    # path_kind_map_back; the promotion hooks call
    # path_kind_paired_test_relocation_targets, the ONLY forward-mapping
    # consumer outside the resolver, so step 6 has a single point to
    # re-home when promotion ownership moves).
    #
    # MAPPING CONTRACT (one reversible, hierarchy-preserving authority):
    #
    #   virtual file-shaped path := tier '/' (name '/')* file
    #     tmp    : relative == virtual      ('task/x/y.rb' <-> 'task/x/y';
    #                                        entity_property/e/p.rb is the
    #                                        nested spelling <e>/<e>.<p>:
    #                                        'e/e.p.rb' below the tier)
    #     project: task/...        -> tasks/...      test_<file>.rb
    #              entity/<n>      -> entity/test_<n>.rb
    #              entity_property/<e>/<p> -> entity/<e>/test_<p>.rb
    #              helper/<n>      -> helper/test_<n>.rb
    #              integration/... -> integration/...  test_<file>.rb
    #              <open tier>/... -> <open>/...       test_<file>.rb
    #
    #   Reversibility rule (what makes it injective, D1+D2 closed):
    #     * DIRECTORY STRUCTURE carries hierarchy (D1: intermediate
    #       directories are never dropped);
    #     * exactly ONE delimiter-anchored transformation — a leading
    #       'test_' prefix added/removed on the FINAL FILENAME ONLY;
    #     * NO name parsing (no underscore splitting/un-flattening), so
    #       underscore-bearing entity/property names cannot collide (D2:
    #       entity_property/demo_widget/tag_palette lives at
    #       entity/demo_widget/test_tag_palette.rb, which no other
    #       accepted virtual path can produce);
    #     * the ONLY tier-directory rename is task -> tasks on the project
    #       side (one fixed substitution);
    #     * integration gets the UNIFORM test_ prefix (D6 closed: the
    #       contradicting per-tier helper was removed in round-10 step 2
    #       and the resolver's exemption is gone).
    #
    # tmp-side entity_property spelling note: the tmp tree keeps the
    # round-9 nested file spelling <entity>/<entity>.<property>.rb under
    # share/test/entity_property/ (created by the authoring draft
    # convention), so the forward map for tmp special-cases that tier's
    # final segment join exactly as before; project side is uniform.

    # Forward leg: validated FILE-shaped segments -> physical relative
    # path (WITH the tier's extension). Prefix/root shapes map through
    # path_kind_map_prefix.
    #
    # Round 11 (python tier): the `python_task` tier lives ONLY at the
    # 'python' location and maps DIRECTLY under that root as
    # test_<name>.py — the legacy scout-rig convention
    # (the retired legacy authoring tool wrote python/test/test_<name>.py).
    # The
    # tier directory is VIRTUAL-ONLY at that location, mirroring how the
    # project side renames task->tasks: one fixed, documented
    # substitution inside this single mapping authority. At the Ruby
    # locations the tier is an OPEN tier with the generic .rb rules
    # (documented as such; the python location is the tier's home).
    def path_kind_map_forward_segments(segments, location)
      tier = segments.first
      file = segments.last
      rest = segments[1..-2]

      if tier == 'python_task' && location.to_s == 'python'
        return 'test_' + [*(segments[1..-2]), file].join('_') + '.py' if segments.length > 2
        return 'test_' + file + '.py'
      end

      case location.to_s
      when 'tmp'
        if tier == 'entity_property'
          # tmp keeps the round-9 nested file spelling <e>/<e>.<p>.rb
          # (entity/property names are [a-z0-9_], never contain '.')
          [tier, *rest, segments[-2] + '.' + file + '.rb'].join('/')
        else
          [tier, *rest, file + '.rb'].join('/')
        end
      when 'project'
        case tier
        when 'entity_property'
          # hierarchy-preserving: entity/<entity>/test_<property>.rb
          ['entity', *rest, 'test_' + file + '.rb'].join('/')
        when 'task'
          ['tasks', *rest, 'test_' + file + '.rb'].join('/')
        else
          [tier, *rest, 'test_' + file + '.rb'].join('/')
        end
      else
        raise ParameterException, "unknown location for test_file kind: #{location}"
      end
    end

    # Prefix shapes (tier selector or nested entity_property/<entity>)
    # map to their directory, no extension. The python tier at the python
    # location has NO tier directory (files sit directly under the root),
    # so every prefix of it IS the location root.
    def path_kind_map_prefix(segments, location)
      tier = segments.first
      rest = segments[1..-1]

      return '' if tier == 'python_task' && location.to_s == 'python'

      dir =
        if location.to_s == 'project'
          case tier
          when 'task' then 'tasks'
          when 'entity_property' then 'entity' # property tests nest under entity/<e>/
          else tier
          end
        else
          tier
        end
      [dir, *rest].join('/')
    end

    # Inverse leg (the list hook's mapping): a physical relative path
    # (with extension) under a location root -> virtual path string.
    # Reverses EXACTLY the forward contract above and nothing else.
    #   tmp    : relative == virtual, except entity_property/<e>/<e>.<p>.rb
    #            -> entity_property/<e>/<p> (first-dot split; entity and
    #            property segments may not contain '.', enforced by the
    #            grammar, so the split is delimiter-anchored).
    #   project: tasks/ -> task/; final file test_ prefix stripped;
    #            entity/<e>/test_<p>.rb -> entity_property/<e>/<p> (the
    #            hierarchy carries the disambiguation: entity virtual
    #            paths are EXACTLY 2 components, grammar-enforced, so a
    #            mid directory under entity/ can only be a property test).
    #   python : test_<name>.py -> python_task/<name>; a test_<a>_<b>.py
    #            under a nested directory -> python_task/<a>/<b> ONLY when
    #            that path resolves back to the same physical file (the
    #            flat join is ambiguous, so the inverse verifies instead
    #            of guessing).
    def path_kind_map_back(relative, location)
      raw = relative.to_s

      if location.to_s == 'python'
        base = raw.sub(/\.py\z/, '')
        return nil unless base =~ /\Atest_(.+)\z/
        joined = Regexp.last_match(1)
        return nil if joined.include?('/')
        # Flat name: the python tier stores test_<name>.py DIRECTLY under
        # the python/test root (the legacy scout-rig convention has no
        # nesting), so a single underscore-bearing name maps back to a
        # single virtual segment — the ambiguous flat-join case never
        # arises. python/test is not a per-tier directory tree; any
        # subdirectory would be outside the convention and is skipped.
        return "python_task/#{joined}"
      end

      if location.to_s == 'tmp'
        stripped = raw.sub(/\.rb\z/, '')
        parts = stripped.split('/')
        if parts[0] == 'entity_property' && parts.length == 3
          property = parts[2].split('.', 2)[1] || parts[2]
          return "entity_property/#{parts[1]}/#{property}"
        end
        return stripped
      end

      parts = raw.sub(/\.rb\z/, '').split('/')
      return parts.join('/') if parts.empty?

      dir_tier = parts.first
      tier = dir_tier == 'tasks' ? 'task' : dir_tier
      base = parts.pop
      base_noprefix = base.sub(/\Atest_/, '')
      mids = parts[1..-1]

      if tier == 'entity' && mids.length == 1
        "entity_property/#{mids[0]}/#{base_noprefix}"
      else
        [tier, *mids, base_noprefix].reject(&:empty?).join('/')
      end
    end

    # PUBLIC ADVISORY MAPPING (round-10 step 6): where a draft's paired
    # test lives, per tier, in BOTH locations. Since the source-kind
    # relocation hooks were removed, this has NO promotion consumer; it is
    # kept as the documented public helper describing the convention
    # (docs/agents, step-9 README), and it is what an agent should consult
    # before promoting a test file alongside its source.
    #
    #   entity  <name>                         (source kind 'entity')
    #   entity_property <entity> <property>    (source kind 'entity_property';
    #                                          note tmp side gets the
    #                                          <entity>/<entity>.<property>.rb
    #                                          spelling via the tmp rule)
    #   task <name...>                         (source kind 'task'; task
    #                                          names may carry directories)
    #
    # Returns {'tmp' => ..., 'project' => ...} relative paths (WITH .rb).
    def path_kind_paired_test_relocation_targets(tier, segments)
      if tier == 'entity_property'
        # the tmp side file is <entity>/<entity>.<property>.rb BELOW the
        # tier directory (round-9 spelling, kept); the project side is
        # entity/<entity>/test_<property>.rb (round-10 hierarchy).
        entity = segments.first
        property = segments.last
        {'tmp' => "entity_property/#{entity}/#{entity}.#{property}.rb",
         'project' => "entity/#{entity}/test_#{property}.rb"}
      else
        {'tmp' => path_kind_map_forward_segments([tier] + segments, 'tmp'),
         'project' => path_kind_map_forward_segments([tier] + segments, 'project')}
      end
    end

    # Historical receiver kept as a synonym of the inverse leg (the list
    # hook and the test-support module keep their call sites).
    def path_kind_virtual_path_for(relative, location)
      PathKindTestFiles.path_kind_map_back(relative, location)
    end


    # ------------------------------------------------------------------
    # Round-10 step 3 — canonical virtual-path grammar + root containment.
    #
    # GRAMMAR (virtual paths of the test_file kind; identical for both
    # locations, decided WITHOUT any filesystem call):
    #
    #   path          := '' | '.' | shaped
    #   shaped        := tier [ '/' name ]+
    #   tier          := 'task' | 'entity' | 'entity_property' | 'helper'
    #                  | 'integration' | <open tier>   (unknown first segment)
    #   name          := plain relative segment
    #
    # Segment rules: non-empty (no '//' or trailing '/'), not '.' (except
    # the whole-path root selector '.'), not '..' (traversal), no NUL or
    # control characters, no backslash, and the FIRST segment must not be
    # '~' (home-expansion risk). A leading '/' (absolute-looking input) is
    # rejected: virtual paths are kind-root-relative by definition.
    # Windows drive-letter spellings ('C:...') are legal POSIX names here
    # and are NOT rejected (noted, not enforced).
    #
    # Shapes (structural; the resolver never guesses file-vs-prefix from
    # filesystem state for VALIDATION — security is decided here and in
    # the containment check, both before any suffix probe):
    #
    #   :root    '' | '.'                          -> the location root
    #   :prefix  <tier>                            -> tier directory
    #            entity_property/<entity>          -> nested prefix
    #   :file    task/<name>                       (2+ components;
    #            entity/<name>                      intermediates allowed:
    #            helper/<name>                      task/<dir>/<name>)
    #            integration/<name> | integration/<feature>/<name>
    #            entity_property/<entity>/<property>   (EXACTLY 3)
    #            <open tier>/<name>...
    #
    # Arity rule (baseline defect D4): entity_property accepts 3 components
    # as a file and 1-2 as a prefix; 4+ components are a ParameterException
    # — they used to alias the 3-component spelling silently.
    def path_kind_test_file_grammar(path)
      raw = path.to_s
      if raw.start_with?('/')
        raise ParameterException,
              "test_file virtual path must be relative to the kind root (got absolute): #{raw.inspect}"
      end

      segments = raw.split('/', -1)
      segments = [] if segments == ['.']
      # split(-1) keeps trailing empties: 'task/x/' -> ['task','x',''] and
      # 'task//x' -> ['task','','x']; the empty-segment rule rejects both.

      segments.each_with_index do |segment, index|
        case
        when segment.empty?
          raise ParameterException,
                "test_file virtual path has an empty segment (double or trailing slash?): #{raw.inspect}"
        when segment == '.'
          raise ParameterException,
                "test_file virtual path segment '.' is not allowed (use the plain path): #{raw.inspect}"
        when segment == '..'
          raise ParameterException,
                "test_file virtual path segment '..' is not allowed (traversal): #{raw.inspect}"
        when segment =~ /[\x00-\x1f\x7f]/
          raise ParameterException,
                "test_file virtual path segment contains a control character: #{segment.inspect}"
        when segment.include?('\\')
          raise ParameterException,
                "test_file virtual path segment contains a backslash: #{segment.inspect}"
        when index.zero? && segment == '~'
          raise ParameterException,
                "test_file virtual path must not start with '~' (home expansion): #{raw.inspect}"
        end
      end

      tier = segments.first
      shape =
        if segments.empty?
          :root
        elsif tier == 'python_task'
          # Round 11 (python tier): the python_task tier lives flat at the
          # python location (python/test/test_<name>.py, the legacy
          # scout-rig convention — one file per tier entry, no nesting),
          # so it carries the same EXACTLY-2 arity gate as entity/helper:
          # python_task/<name>.
          case segments.length
          when 1
            :prefix
          when 2
            :file
          else
            raise ParameterException,
                  "python_task test path must be python_task/<name> (2 components) or the python_task prefix; got #{segments.length} components: #{raw.inspect}"
          end
        elsif tier == 'entity_property'
          case segments.length
          when 1, 2
            :prefix
          when 3
            :file
          else
            raise ParameterException,
                  "entity_property test path must be entity_property/<entity>/<property> (3 components) or a 1-2 component prefix; got #{segments.length} components: #{raw.inspect}"
          end
        elsif tier == 'entity' || tier == 'helper'
          # EXACTLY 2 components (tier/name). Round-10 step 4: the
          # project-side entity_property layout is entity/<entity>/
          # test_<property>.rb, so 3-component entity paths would make the
          # mapping non-injective; the arity gate keeps it reversible.
          case segments.length
          when 1
            :prefix
          when 2
            :file
          else
            raise ParameterException,
                  "#{tier} test path must be #{tier}/<name> (2 components) or the #{tier} prefix; got #{segments.length} components: #{raw.inspect}"
          end
        elsif tier == 'integration'
          # <feature> grouping allowed: integration/<name> or
          # integration/<feature>/<name>
          case segments.length
          when 1
            :prefix
          when 2, 3
            :file
          else
            raise ParameterException,
                  "integration test path must be integration/<name> or integration/<feature>/<name>; got #{segments.length} components: #{raw.inspect}"
          end
        else
          segments.length == 1 ? :prefix : :file
        end

      {'shape' => shape, 'tier' => tier, 'segments' => segments, 'path' => raw}
    end

    # Symlink-aware containment at the resolve boundary: the deepest
    # EXISTING ancestor of the candidate must realpath INSIDE the real
    # root. The nonexistent suffix is safe because the grammar already
    # rejected '..' and absolute input, so only a symlinked directory can
    # redirect the path — and realpath resolves symlinks on both sides,
    # which also makes the check bind-spelling-proof (/home vs /bulk).
    def path_kind_assert_test_file_containment!(candidate, root, path, location)
      root_real = File.realpath(root.to_s) rescue File.expand_path(root.to_s)

      # Resolve the deepest EXISTING ancestor (symlinks resolve there), then
      # re-attach the non-existent suffix: a path whose parent directories
      # are not created yet cannot be redirected by not-yet-existing
      # symlinks, so lexical containment of the suffix under the resolved
      # ancestor is sound.
      probe = candidate.to_s
      suffix = +''
      until File.exist?(probe)
        parent = File.dirname(probe)
        raise ParameterException,
              "test_file containment check walked past the filesystem root for #{candidate.inspect}" if parent == probe
        suffix = File.basename(probe) + (suffix.empty? ? '' : File::SEPARATOR + suffix)
        probe = parent
      end
      real = File.realpath(probe)
      full = suffix.empty? ? real : File.join(real, suffix)

      return true if full == root_real || full.start_with?(root_real + File::SEPARATOR)

      raise ParameterException,
            "test_file path '#{path}' (location #{location}) resolves outside the kind root: #{candidate} -> #{full} (root #{root_real})"
    end
  end

  # -------------------------------------------------------------------------
  # The test_file kind definition
  # -------------------------------------------------------------------------
  # Round-10 step 6 (registration-time capture): 'roots' and 'description'
  # are built by path_kind_test_file_definition — a METHOD, evaluated when
  # the kinds are REGISTERED (engine register_path_kind pins roots then;
  # workflow incorporation copies the constant and registers the copy), not
  # when this file is merely loaded. This is what keeps a differently-named
  # workflow incorporating these kinds from inheriting ScoutCoder's own
  # project-side tree: each incorporation resolves target_workflow_name for
  # ITSELF at registration. The lambda declarations below are still shared
  # by reference; the dynamic lookups they call keep working for every
  # registered root.
  # The caller supplies the workflow identity when incorporating (defaults
  # to ScoutCoder's own, for the single-registration flow below).
  def self.path_kind_test_file_definition(workflow_name = target_workflow_name)
    {
    'name' => 'test_file',
    'description' =>
      "Unit and integration test files for #{target_workflow_name} (drafts in share/test, " \
      "promoted copies in test/#{target_workflow_name}). " \
      'Virtual paths are relative to the kind root: first segment is the tier ' \
      '(task, entity, entity_property, helper, integration), e.g. task/greet_user or ' \
      "integration/round_trip; no .rb suffix, no physical prefix (share/test/, test/#{target_workflow_name}/), " \
      'and "." is a root selector only for enumeration (path_list, run_test suite scope). ' \
      'Paired-test tiers: task -> share/test/task/<name>.rb -> test/' + target_workflow_name + '/tasks/test_<name>.rb; ' \
      'entity -> share/test/entity/<Type>.rb -> test/' + target_workflow_name + '/entity/test_<Type>.rb ' \
      '(<Type> is the entity-type name in its OWN spelling — CamelCase is canonical ' \
      '(DemoWidget), legacy snake_case keeps its snake spelling per the decision artifact; ' \
      'the map is parsing-free, virtual path == file basename); ' \
      'entity_property -> share/test/entity_property/<Type>/<Type>.<property>.rb -> ' \
      'test/' + target_workflow_name + '/entity/<Type>/test_<property>.rb (tmp side is ' \
      '<Type>/<Type>.<property>.rb, NOT <Type>/<property>.rb); ' \
      'integration -> share/test/integration/<name>.rb -> test/' + target_workflow_name + '/integration/test_<name>.rb.',
    'extension' => 'rb',
    'locations' => ['tmp', 'project', 'python'],
    'default_location' => 'tmp',
    'roots' => {
      'tmp' => Scout.share.test,
      'project' => Scout.root.test[target_workflow_name],
      # Round 11 (python tier): the legacy scout-rig home for Python
      # tests, python/test/ (the retired legacy authoring tool wrote
      # test_<name>.py there). Engine authorization is per-location
      # root, so this third root is its own grant; the python_task tier
      # of the virtual grammar maps into it (see the mapping authority).
      'python' => Scout.python.test
    },
    'sandbox' => true,
    'capabilities' => {
      'read' => true, 'write' => true, 'edit' => true, 'list' => true,
      'move' => true, 'rename' => true, 'delete' => true,
      'validate' => true, 'promote' => true
      # 'smoke' => false (round-10 decision: test_file has NO smoke; the
      #                   static `validate` plus the executing `run_test`
      #                   cover it — run_test reports `executed`/`passed`
      #                   and exit status separately, so the old
      #                   ran-OK-even-if-failing smoke verdict is redundant)
      # 'patch' => false (default off, same as the source kinds)
      # 'test' => false (default; the operation is being removed from the
      #                 engine and nothing may be registered under `test`)
    },

    # Virtual path -> absolute target, per location. The hook OWNS the
    # extension (the engine skips its default set_extension when a resolve
    # hook exists) and must keep targets under the location root or
    # authorization fails. Empty or `.` paths resolve to the location root
    # itself (used by directory / suite scopes).
    'resolve' => lambda do |agent, path, location|
      ScoutCoder.path_kind_resolve_test_file(path, location, agent)
    end,
    # (Round 11: the resolve hook stays keyed to the production 'test_file'
    # registration; the empty-suite probe and any differently-named kind
    # copy must NOT carry this hook — see the regression suite note.)

    # Real files under the location root -> virtual spellings, so
    # path_list round-trips with path_read / run_test.
    'list' => lambda do |agent, prefix, location|
      ScoutCoder.path_kind_list_test_files(prefix, location, agent)
    end,
    # (Round 11, same convention as resolve: the list hook is production-
    # 'test_file'-keyed; a sandbox copy must drop it too, or its pinned
    # roots are ignored in favor of the production registration's.)

    # Static shape checks; never executes the target.
    'validate' => lambda do |agent, path, location, args|
      ScoutCoder.path_kind_validate_test_file(agent, path, location)
    end,

    # (Round 10: the 'smoke' handler is removed. test_file has NO smoke —
    # `validate` is the static check and `run_test` is the executing check,
    # reporting `executed`/`passed` and the exit status separately.)

    # Declarative destination; NO promotion_post_move hook (a test has no
    # paired test). The engine resolves the same virtual path at the
    # project location through the resolve hook, which rewrites the
    # spelling, and performs the move itself.
    'promotion_destination' => 'project',

    'operations' => {
      'run_test' => {
        'description' => 'Run test files: one file, every file under a path prefix, or the entire suite, each in a fresh Ruby process. Each child loads the workflow.rb of the project checkout that owns the test file (ENV PATH_KIND_PROJECT_ROOT overrides). Virtual test paths are relative to the test_file kind root: tier/name such as task/greet_user, no .rb suffix, no physical prefix; "." is the suite-root selector.',
        'parameters' => {
          'properties' => {
            'scope' => {'type' => 'string', 'enum' => %w[file directory suite], 'default' => 'file',
                        'description' => 'OPTIONAL (default file). file: run the single test file at path. directory: run every test file under the path prefix. suite: run every discovered test file in both locations (path is the root selector; use ".").'},
            'timeout_seconds' => {'type' => 'integer', 'default' => 120,
                                  'minimum' => TestFileSupport::MIN_TIMEOUT,
                                  'maximum' => TestFileSupport::MAX_TIMEOUT,
                                  'description' => "OPTIONAL per-file timeout in seconds, #{TestFileSupport::MIN_TIMEOUT}..#{TestFileSupport::MAX_TIMEOUT} (default 120; 300 for suite scope). Out-of-range or non-integer values are rejected."}
          }
          # (Round 10, step 6: `required` dropped — scope is optional with
          # default 'file'; the engine's contract merge already requires
          # kind+path. The old schema required scope AND defaulted it.)
        },
        'implementation' => lambda do |agent, target, args|
          # Round-11 conformance: derive the DISPATCHED kind from the pinned
          # root that authorization just validated (target's location root)
          # rather than a kind name — the engine strips 'kind' from args
          # before calling here. TestFileSupport resolves suite roots from
          # `target`, so the empty-root probe and foreign incorporations
          # enumerate THEIR OWN trees without a name round-trip.
          ScoutCoder::TestFileSupport.run_for_agent(agent, target, args)
        end,
        'authorization' => :read,
        'type' => :full
      }
    }
    }
  end

  # Registration-time snapshot for THIS process (single-incorporation flow):
  # the aggregator merges it into ScoutCoder::PATH_KINDS so workflow.rb's
  # require gate and whole-workflow incorporation see exactly the same
  # shape as before, while path_kind_test_file_definition stays the
  # re-evaluable authority for any OTHER workflow registering the kinds.
  PATH_KIND_TEST_FILE_DEFINITION = path_kind_test_file_definition.freeze

  class << self
    # Round-10 step 6 helper: the REGISTERED root for this agent's
    # test_file definition, used when the incorporating workflow is NOT
    # ScoutCoder itself (foreign incorporation resolves its own tree);
    # returns nil for ScoutCoder's own checkout (dynamic Scout-map lookup
    # stays primary there so the CWD-anchored sandbox keeps working) and for
    # direct calls without an agent (task surface, probes, tests).
    # The STRUCTURAL anchor is captured at file load (this checkout), NOT
    # the swap-able PATH_KIND_ROOT the regression suite mutates: the
    # own-checkout exception must survive root swapping.
    STRUCTURAL_CHECKOUT = File.expand_path('../../..', __dir__.freeze)

    def path_kind_registered_root(agent, location)
      return nil unless agent.respond_to?(:path_kind_definition)
      defn = (agent.path_kind_definition('test_file') rescue nil)
      return nil unless defn.is_a?(Hash) && defn['roots'].is_a?(Hash)
      r = defn['roots'][location.to_s]
      return nil if r.nil?
      r = r.is_a?(String) ? Path.setup(r) : r
      own = STRUCTURAL_CHECKOUT
      resolved = r.find(:current).to_s
      return nil if resolved == own || resolved.start_with?(own + '/')
      r
    end

    # Round 11 (python tier): the probe-copy convention (the suite's
    # sandbox_kind! copies drop the resolve/list hooks, so resolution must
    # flow through the COPY's pinned roots) needs a root lookup that also
    # honors a differently-named kind copy. Kept separate from
    # path_kind_registered_root because the production 'test_file'
    # preference (with its own-checkout exception) must stay primary for
    # the real registration.
    def path_kind_any_registered_root(agent, kind, location)
      return nil unless agent.respond_to?(:path_kind_definition)
      defn = (agent.path_kind_definition(kind) rescue nil)
      return nil unless defn.is_a?(Hash) && defn['roots'].is_a?(Hash)
      r = defn['roots'][location.to_s]
      return nil if r.nil?
      r = r.is_a?(String) ? Path.setup(r) : r
      own = STRUCTURAL_CHECKOUT
      resolved = r.find(:current).to_s
      return nil if resolved == own || resolved.start_with?(own + '/')
      r
    end

    # Virtual path -> absolute target, per location.
    #
    # Round-10 step 3: the path is FIRST validated against the canonical
    # grammar (path_kind_test_file_grammar — structural checks, zero
    # filesystem calls), then mapped, then containment-checked
    # (path_kind_assert_test_file_containment! — symlink-aware, root
    # containment) BEFORE the returned target is used. The historical
    # `File.directory?`-driven file-vs-directory guess is retained ONLY as
    # the suffix heuristic (does the path need `.rb` appended?) and runs
    # strictly AFTER validation; it no longer decides security.
    def path_kind_resolve_test_file(path, location, agent = nil)
      parsed = path_kind_test_file_grammar(path)
      segments = parsed['segments']
      shape = parsed['shape']

      # Round-10 step 6 (round 11: python added): prefer the REGISTERED
      # root (registration-time capture — engine register_path_kind pins
      # it) over recomputing from the dynamic workflow name, so an
      # incorporation by a differently named workflow resolves into ITS
      # OWN tree. The own-checkout exception lives in the helper: when the
      # registered root is INSIDE ScoutCoder's own structural checkout,
      # nil is returned and the Scout-map dynamic lookup stays primary —
      # the single-registration flow where the suite's CWD-anchored
      # sandbox (swapped PATH_KIND_ROOT + process CWD) must keep working.
      root = path_kind_registered_root(agent, location)
      root ||=
        case location.to_s
        when 'tmp'    then Scout.share.test
        when 'project' then Scout.root.test[ScoutCoder.target_workflow_name]
        when 'python' then Scout.python.test
        else
          raise ParameterException, "unknown location for test_file kind: #{location}"
        end

      # Round 11 (python tier): the python location hosts ONLY the
      # python_task tier; a FILE-shaped request for another tier at that
      # location is a ParameterException, not a silent generic mapping
      # (one home per tier, one tier per home). Root and PREFIX selectors
      # are exempt: suite scope addresses the root, and a foreign-tier
      # prefix legitimately lists nothing at this location.
      if location.to_s == 'python' && shape == :file && parsed['tier'] != 'python_task'
        raise ParameterException,
              "test_file location 'python' hosts only the python_task tier (got #{parsed['tier'].inspect})"
      end

      case location.to_s
      when 'tmp'
        return root.find(:current) if shape == :root
        # Tier-directory selectors resolve to the directory itself (used by
        # directory / suite scopes); only a LAST segment is treated as a
        # file name. The mapping itself is delegated to the single
        # authority (round-10 step 4); the directory probe below ONLY
        # decides whether the shape resolves as a directory that already
        # exists (a prefix selector that shadows a file spelling).
        if shape == :file
          base = File.join(root.find(:current).to_s,
                           path_kind_map_forward_segments(segments, 'tmp'))
        else
          base = File.join(root.find(:current).to_s,
                           path_kind_map_prefix(segments, 'tmp'))
        end
        candidate = Path.setup(base).find(:current)
        path_kind_assert_test_file_containment!(candidate, root.find(:current), path, location) unless shape == :root
        candidate
      when 'project'
        return root.find(:current) if shape == :root
        if shape == :file
          base = File.join(root.find(:current).to_s,
                           path_kind_map_forward_segments(segments, 'project'))
        else
          base = File.join(root.find(:current).to_s,
                           path_kind_map_prefix(segments, 'project'))
        end
        candidate = Path.setup(base).find(:current)
        path_kind_assert_test_file_containment!(candidate, root.find(:current), path, location)
        candidate
      when 'python'
        # Root and prefix selectors both address the location root: the
        # python tier has no physical tier directory (files sit directly
        # under python/test), so a file shape maps to test_<name>.py.
        return root.find(:current) if shape == :root || shape == :prefix
        base = File.join(root.find(:current).to_s,
                         path_kind_map_forward_segments(segments, 'python'))
        candidate = Path.setup(base).find(:current)
        path_kind_assert_test_file_containment!(candidate, root.find(:current), path, location)
        candidate
      else
        raise ParameterException, "unknown location for test_file kind: #{location}"
      end
    end

    # List hook (round-10 step 5): prefix-honoring listing through the same
    # grammar + single mapping authority the resolver uses.
    #
    # CONTRACT
    #   input  : any grammar-valid virtual path — :root ('' / '.'),
    #            :prefix (tier or tier/… selector) or :file shape.
    #   output : SORTED array of virtual spellings (the same form resolve
    #            accepts), covering EXACTLY the file-shaped descendants of
    #            the input in the virtual tree.
    #              :root   -> every test file under the location root
    #              :prefix -> descendants of that prefix only (never
    #                         siblings, never the whole root)
    #              :file   -> [itself] when the file exists, [] otherwise
    #   missing-but-well-formed prefix/file -> EMPTY LIST (absence is a
    #            legitimate empty answer for listing; malformed input stays
    #            a grammar ParameterException — enforced by the grammar
    #            call below, before any FS access).
    #   determinism: entries are sorted; two calls agree exactly.
    #
    # Physical side: glob the mapped prefix DIRECTORY, inverse-map every
    # hit through path_kind_map_back, then keep exactly the virtual
    # descendants of the request (this also drops any physical file that
    # does not inverse-map into the virtual tree, e.g. stray non-test
    # .rb files in the root).
    def path_kind_list_test_files(prefix, location, agent = nil)
      parsed = path_kind_test_file_grammar(prefix)
      segments = parsed['segments']
      shape = parsed['shape']

      # Round-10 step 6: registered-root preference, same as the resolver
      # (including the own-checkout exception that keeps the suite's
      # CWD-anchored sandbox effective).
      root = path_kind_registered_root(agent, location)&.find(:current)
      root ||=
        case location.to_s
        when 'tmp'
          Scout.share.test.find(:current)
        when 'project'
          Scout.root.test[ScoutCoder.target_workflow_name].find(:current)
        when 'python'
          Scout.python.test.find(:current)
        else
          raise ParameterException, "unknown location for test_file kind: #{location}"
        end

      # Round 11 (python tier): the python location lists ONLY the
      # python_task tier, directly under its root.
      if location.to_s == 'python'
        parsed_tier = parsed['tier']
        if shape == :file || shape == :prefix
          # A file/prefix selector for another tier names nothing at this
          # location: EMPTY (well-formed), matching the missing-tier rule.
          return [] unless parsed_tier == 'python_task'
        end
        physical_dir = root.to_s
        pattern = File.join(physical_dir, '*.py')
        virtuals = Dir.glob(pattern).sort.map do |file|
          relative = file.sub(%r{\A#{Regexp.escape(root.to_s)}/}, '')
          begin
            PathKindTestFiles.path_kind_map_back(relative, location)
          rescue ParameterException
            nil # physical .py that is not a valid virtual mapping: skip
          end
        end.compact.uniq
        # File/prefix/root selectors all address the same flat directory;
        # a file selector additionally filters to itself when present.
        return virtuals.select { |v| v == segments.join('/') } if shape == :file
        return virtuals
      end


      # :file shape — exact file request: [spelling] when the mapped file
      # exists. P2(e) resolution for the LIST direction: when no such file
      # exists but a DIRECTORY does at the same spelling (possible only for
      # tiers with open depth — task and open tiers — where a 2+ component
      # path is grammar-:file yet was intended as a nested prefix), list
      # its descendants instead of returning a surprising empty result.
      # RESOLVE keeps strict shape semantics; only listing resolves the
      # file-or-directory ambiguity by existence.
      if shape == :file
        physical = File.join(root.to_s, path_kind_map_forward_segments(segments, location))
        return [segments.join('/')] if File.file?(physical)

        dir_probe = File.join(root.to_s, path_kind_map_prefix(segments, location))
        if File.directory?(dir_probe)
          physical_dir = dir_probe
        else
          return []
        end
      else
        physical_dir =
          if shape == :root
            root.to_s
          else
            File.join(root.to_s, path_kind_map_prefix(segments, location))
          end
        return [] unless File.directory?(physical_dir)
      end

      pattern = File.join(physical_dir, '**', '*.rb')
      virtuals = Dir.glob(pattern).sort.map do |file|
        relative = file.sub(%r{\A#{Regexp.escape(root.to_s)}/}, '')
        begin
          PathKindTestFiles.path_kind_map_back(relative, location)
        rescue ParameterException
          nil # physical .rb that is not a valid virtual mapping: skip
        end
      end.compact

      wanted_prefix =
        if shape == :root
          ''
        else
          segments.join('/') + '/'
        end

      virtuals.uniq.sort.select do |v|
        v.start_with?(wanted_prefix)
      end
    end

    # Static validation of one test file. Never executes the target.
    def path_kind_validate_test_file(agent, path, location)
      target = agent.resolve_path('test_file', path, location)

      envelope = lambda do |reasons, warnings|
        {'ok' => reasons.empty?, 'kind' => 'test_file', 'op' => 'validate',
         'path' => path, 'location' => location,
         'class' => path.to_s.split('/').first == 'integration' ? 'integration' : 'unit',
         'reasons' => reasons, 'warnings' => warnings}
      end

      unless File.file?(target.to_s)
        return envelope.call(["target does not exist or is not a file: #{target}"], [])
      end

      source = File.read(target.to_s)
      reasons = []
      warnings = []

      begin
        RubyVM::AbstractSyntaxTree.parse(source)
      rescue SyntaxError => e
        reasons << "syntax error: #{e.message.to_s.lines.first.to_s.strip}"
      end

      if reasons.empty?
        requires_harness = !!(source =~ /require\s+['"]test\/unit['"]/ ||
                              source =~ /require\s+\S*test_helper['"]/)
        declares_case = !!(source =~ /<\s*Test::Unit::TestCase/)
        declares_test = !!(source =~ /^\s*def\s+test_/)

        if !requires_harness && !declares_case
          reasons << 'neither requires the test harness nor declares a Test::Unit::TestCase subclass'
        elsif !requires_harness || !declares_case
          warnings << (requires_harness ?
                         'requires the harness but declares no Test::Unit::TestCase subclass' :
                         'declares a TestCase subclass but does not require the harness')
        end

        warnings << 'no `def test_` method declared' unless declares_test
      end

      base = File.basename(path.to_s)
      if location.to_s == 'project' && base !~ /\Atest_/
        warnings << "project-side test file lacks the `test_` prefix (#{base})"
      elsif location.to_s == 'tmp' && base =~ /\Atest_/
        warnings << "tmp-side test file carries a `test_` prefix (#{base}); share-side tests are unprefixed"
      end

      envelope.call(reasons, warnings)
    end

    # Directory the fresh-process children load the workflow from. Anchor
    # contract (round: path-kinds contract fixes, discharging round-9
    # deferred item 8): a run_test child loads the workflow.rb of the
    # project checkout that OWNS the resolved test file. Priority:
    #   1. ScoutCoder::PATH_KIND_PROJECT_ROOT when set — explicit override;
    #      the regression suite seam (test_path_kinds.rb) depends on it.
    #   2. The checkout owning the RESOLVED TEST FILE (marker climb, see
    #      owner_checkout). This is the session regime: kinds incorporated
    #      from this structural checkout while the agent works from a
    #      foreign project — the pinned kind root is ScoutCoder's OWN, so
    #      it cannot identify the foreign project; the resolved target can.
    #   3. The pinned kind root's project, when the kinds were registered
    #      by a FOREIGN project (its pinned root IS that project).
    #   4. PATH_KIND_ROOT (structural ScoutCoder) when nothing identifies
    #      a project (e.g. a sandbox file under no checkout).
    # The aggregator forwards it to `ScoutCoder.child_checkout`, and
    # `TestFileSupport.run_child` calls exactly that (via respond_to?) for
    # run_test children. Removed once in round 10 by mistake; the run_test
    # suite failed immediately — kept.
    def child_checkout(file: nil, pinned_root: nil)
      (ScoutCoder.const_defined?(:PATH_KIND_PROJECT_ROOT, false) &&
        ScoutCoder::PATH_KIND_PROJECT_ROOT) ||
        owner_checkout(file) ||
        pinned_project_root(pinned_root) ||
        ScoutCoder::PATH_KIND_ROOT
    end

    # ScoutCoder: a Scout checkout is anchored by `workflow.rb`, and the
    # framework's own marker climb is Path.caller_lib_dir (scout-essentials
    # lib/scout/path/find.rb) — Workflow.extended anchors a workflow's
    # libdir with its default lib/bin/README.md markers, which is why a
    # foreign checkout without one of those markers has its libdir climbed
    # PAST it to the enclosing project. Reusing the helper with the
    # workflow.rb marker finds the owning checkout of any file without a
    # new marker scheme.
    def owner_checkout(file)
      return nil if file.nil? || file.to_s.empty?
      root = Path.caller_lib_dir(File.dirname(File.expand_path(file.to_s)), ['workflow.rb'])
      root.nil? || root.to_s.empty? ? nil : root.to_s
    end

    # Step 3 anchor: the pinned kind root belongs to a foreign project only
    # when it is NOT inside this structural checkout (same own-checkout
    # exception as path_kind_registered_root). <project>/share/test -> the
    # project root; conservative: only accepted when it really is a
    # workflow checkout (workflow.rb present).
    def pinned_project_root(pinned_root)
      return nil if pinned_root.nil? || pinned_root.to_s.empty?
      resolved = Path.setup(pinned_root.to_s).find(:current).to_s
      own = STRUCTURAL_CHECKOUT
      return nil if resolved == own || resolved.start_with?(own + '/')
      candidate = File.expand_path('../..', resolved)
      File.exist?(File.join(candidate, 'workflow.rb')) ? candidate : nil
    end

    # (Round 10: `smoke_timeout_for` and `path_kind_smoke_test_file` were
    # removed together with the smoke capability and its tests.)
  end
end
