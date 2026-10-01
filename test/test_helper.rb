require 'test/unit'
$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib')))
$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)))
# Load the project workflow so source files that declare Workflow DSL tasks
# can be required directly by tests using the repository test convention.
require File.expand_path('../workflow', __dir__)

