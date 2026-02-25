module ScoutCoder
  desc 'Read the files and explain the code'
  input :files, :path_array, 'List of files to examine', nil, required: true
  task :explain_code => :text do |files|
    agent = self.agent
    files.each do |file|
      raise ParameterException, "File not readable #{file}" unless Open.exists?(file) && ! Open.directory?(file)
      agent.file file
    end

    agent.task ScoutCoder, :documentation_overview

    agent.user <<-EOF
Please explain the code found in the files.
Read the scout documentation as you need it.
    EOF


    agent.chat
  end

  desc 'Read the file and make a summary'
  input :file, :path, 'File to examine', nil, required: true
  task :summarize_file => :text do |file|
    raise ParameterException, "File not readable #{file}" unless file && Open.exists?(file) && ! Open.directory?(file)
    agent = self.agent nil
    agent.file file

    agent.user <<-EOF
Summarize this file
    EOF

    agent.chat
  end

  desc 'Explore a directory structure and return a description of the contents'
  input :directory, :path, 'Directory to traverse', nil, required: true
  task :explore_directory_structure => :text do |directory|
    agent = self.agent

    agent.user <<-EOF

# Task

Write a markdown description of the contents of #{directory}, assumed to contain
a project e.g. like a software project or a data analysis project.

# Instructions

- Use markdown to format the output
- Make the description useful for other AI agents to navigate the files in the directory
- You may list and read files using the 'list_directory' and 'read' tools
- Try not to overload your own context reading too many files, make use of the 'file_stats' and 'summarize_file' to help you see how large files are and synthezise short descriptions; 
- If you identify code files that are related, you can use 'explain_code' to get an explanation of the code on all those files

Use the tools list_directory, read, file_stats, summarize_file, explain_code,
etc. to traverse the directory structure under directory #{File.expand_path directory} 
and return a description of what you find. You may use the repo
documentation to help you understand what you find in the files

Try not to load into context large files, consider instead using the summarize_file tool.

You may ask for the output of several tools at the same time, for instance to summarize
a list of files in one go.
    EOF

    agent.task ComputerUse, :list_directory, directory: directory, recursive: true, stats: true

    agent.user <<-EOF
Before you write your final report, plan what topics to write about and how
they would help other agents, and use them as the structure of the final
document. 

Aim for a concise document that serves as a guide to other agents to
know what the project is about and what they can expect to find and were. 
If they are interested in the project they can use this guide to 
quickly know where to start.
    EOF

    agent.chat

    agent.import ScoutCoder.prompts.return.markdown.find

    agent.user <<-EOF
Now produce the full markdown content following the draft structure you generated ealier
    EOF

    begin
      agent.chat
    ensure
      agent.save file('chat')
    end
  end
end
