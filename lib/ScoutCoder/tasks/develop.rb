module ScoutCoder

  input :prompt, :text, "Prompt describing what to implement"
  task :implement => :text do |prompt|

    developer = agent workflow: ComputerUse
    developer.start_chat.tool ScoutCoder
    developer.start_chat.import ScoutCoder.prompts.developer.find

    supervisor = agent workflow: ScoutCoder
    supervisor.start_chat.import ScoutCoder.prompts.supervisor.find
    supervisor.delegate developer, :developer, <<-EOF
Ask the developer to implement something. 
    EOF

    agent = self.agent
    agent.delegate supervisor, :supervisor, <<-EOF
Ask a supervisor to take care of a task. 
    EOF

    agent.user <<-EOF 

Please follow the following instructions:

---
#{prompt}
    EOF

    agent.chat
  end

  export_exec :implement
end
