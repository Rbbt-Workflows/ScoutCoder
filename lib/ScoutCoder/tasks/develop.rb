module ScoutCoder

  input :prompt, :text, "Prompt describing what to implement"
  task :plan => :text do |prompt|

    agent = agent 'ScoutCoder'

    agent.task ScoutCoder, :documentation_overview

    agent.system <<-EOF 
You peform the planning step solving a problem. You need to
produce a three part document. First comes a section called
Overview were you make sense of what the user is asking in
clear terms. Then you have a section called Approach with
a description of how it will be solved in general terms. Finally
there is a section called Steps were there a list of steps, 
each having a title and a description, with all the steps
that need to be executed to perform the task.  

You are given access to a number of tools that you can use to
examine the contents of the project directory, as well
as to consult relevant documentation. In the Approach
section make reference to relevant portions of the project and
how it is designed.
    EOF

    agent.user <<-EOF 
Plan how to execute the following:

#{prompt}

    EOF

    agent.chat
  end

  dep :plan
  task :implement => :text do

    developer = agent 'ScoutCoder'
    developer.task ScoutCoder, :documentation_overview
    developer.start_chat.tool ScoutCoder
    developer.start_chat.import ScoutCoder.prompts.developer.find

    supervisor = agent 'ScoutCoder'
    supervisor.task ScoutCoder, :documentation_overview
    supervisor.start_chat.import ScoutCoder.prompts.supervisor.find
    supervisor.delegate developer, :developer, <<-EOF
Ask the developer to implement something. Provide detail instructions.
    EOF

    agent = self.agent
    agent.delegate supervisor, :supervisor, <<-EOF
Ask a supervisor to take care of a task.    EOF
    EOF

    agent.user <<-EOF 
Please follow the following instructions and ask a supervisor to take care of
each step Use the ./doc/ directory to save files with documentation that you
can ask the developer agent to read. Before you hand off a task, make sure
you have prepared enough documentation and that you craft an appropriate 
prompt.
---
#{step(:plan).load}
    EOF

    agent.chat
  end
end
