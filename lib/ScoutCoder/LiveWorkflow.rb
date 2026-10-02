module ScoutCoder
  # LiveWorkflow is extended by target workflows so their authoring drafts
  # under <workflow>.libdir.share are loaded dynamically on every workflow.rb
  # (re)load. Load order on every pass: share/tasks, share/helpers,
  # share/entities, share/entity_properties. Entity definitions are loaded
  # before their property files so the entity modules are available for
  # property registration.
  module LiveWorkflow
    # Ordered share subdirectories: tasks, helpers, entities, then entity
    # properties. Entity files always precede property files.
    SHARE_SUBDIRS = %w[tasks helpers entities entity_properties].freeze

    def self.extended(base)
      base.load_live_files!
    end

    # Resolve the share directory of the extending workflow. `libdir` is set
    # by Workflow.extended through Path.caller_lib_dir, and libdir is a Path,
    # so `libdir.share` is a plain string join ("<libdir>/share") that does
    # not traverse path maps: we want the checkout's own share, not a
    # resolved or produced one. Uses the target workflow's libdir, never
    # ScoutCoder's, so every extending workflow loads its own drafts.
    # Returns nil when the workflow has no libdir, which makes loading a
    # silent no-op.
    def self.share_directory(base)
      return nil if base.nil? || !base.respond_to?(:libdir) || base.libdir.nil?
      File.expand_path(base.libdir.share.to_s)
    end

    # Flat, ordered list of draft files: the four share subdirectories in
    # order, each sorted with top-level files before nested ones and
    # lexicographic within a level, so loads are deterministic. Missing or
    # empty directories (and a missing share/ itself) contribute nothing.
    # Only *.rb files are selected, so identifier TSVs at
    # share/entity/<entity>.identifiers.tsv are never loaded, and share/test
    # is never touched (task tests run in fresh processes instead).
    def self.ordered_share_files(base)
      share = share_directory(base)
      return [] if share.nil?
      SHARE_SUBDIRS.flat_map do |sub|
        Dir.glob(File.join(share, sub, '**', '*.rb')).sort_by do |file|
          [file.count(File::SEPARATOR), file]
        end
      end
    end

    # Explicit reload for the loaded-but-not-re-executed case. The extended
    # hook and this method share this single implementation, so re-running
    # workflow.rb (Workflow.require_workflow with update: true, which
    # re-fires Module#extended) and calling the function behave identically.
    #
    # Files are loaded with `load` (not require) so they re-execute on every
    # reload. They are expected to wrap themselves in their workflow module
    # (the convention of TaskDefinition.source and the helper generator), so
    # task, helper and entity DSL declarations register on the workflow.
    #
    # ScoutCoder: `base.module_eval { load file }` does NOT make the loaded
    # file see base as self; Kernel#load always evaluates the file at
    # top-level (self=main), which is why draft files must wrap themselves
    # in their workflow module. Verified empirically with probes before this
    # module was written; document this in Workflow docs if it is not there.
    #
    # Re-loading never raises on re-declaration: tasks reassign, helpers
    # redefine, and re-extending Entity is expected. Removed files leave
    # their tasks/modules in memory for the process lifetime (Ruby cannot
    # unload constants or methods); a fresh process clears them, so removal
    # is tolerated here and simply stops re-registering.
    def load_live_files!
      LiveWorkflow.ordered_share_files(self).each do |file|
        load file
      end
      self
    end
  end
end
