module ScoutCoder
  desc 'List all known entity modules and metadata'
  task :list_entities => :json do
    root = EntityDefinitionSupport.project_root
    EntityDefinitionSupport.entity_modules.map do |entity|
      EntityDefinitionSupport.entity_inspection(entity, root)
    end.sort_by { |entry| entry[:name] }
  end
  export_exec :list_entities
end
