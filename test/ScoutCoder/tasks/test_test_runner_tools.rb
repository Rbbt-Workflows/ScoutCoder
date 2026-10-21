require 'test/unit'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'
require File.expand_path('../../test_helper.rb', __dir__)

# Round 9 (guide research/test-file-path-kind-guide.md §8 items 11-13 + the
# run_test task): the aggregated `run_test` custom operation and the
# ScoutCoder `run_test` task, exercised through the same TestFileSupport.
# Runs against sandbox tmpdirs with the process CWD confined, so nothing
# touches the real share/test or test/ScoutCoder trees.
class TestTestRunnerTools < Test::Unit::TestCase
  ROOT = File.expand_path('../../..', __dir__)
  PASS = <<~RUBY
    require 'test/unit'
    class PassFixture < Test::Unit::TestCase
      def test_ok; assert_equal 1, 1; end
    end
  RUBY
  FAIL = <<~RUBY
    require 'test/unit'
    class FailFixture < Test::Unit::TestCase
      def test_fails; assert_equal 1, 2; end
    end
  RUBY

  def setup
    @sandbox = Dir.mktmpdir('r9-run-test')
    @saved_cwd = Dir.pwd
    @before = snapshot_real
  end

  def teardown
    Dir.chdir(@saved_cwd) if Dir.pwd != @saved_cwd
    FileUtils.rm_rf(@sandbox)
    after = snapshot_real
    assert_equal @before.keys, after.keys, 'must not write in the real tree'
    @before.each do |path, digest|
      assert_equal digest, after[path], "#{path} must be unchanged"
    end
  end

  def snapshot_real
    [File.join(ROOT, 'share', 'test'), File.join(ROOT, 'test', 'ScoutCoder')].each_with_object({}) do |root, h|
      Dir.glob(File.join(root, '**', '*.rb')).sort.each { |f| h[f] = File.mtime(f) }
    end
  end

  def run_tool(path, scope, timeout: nil)
    args = { 'kind' => 'test_file', 'path' => path, 'scope' => scope, 'location' => 'tmp' }
    args['timeout_seconds'] = timeout if timeout
    raw = @agent.other_options[:tools]['run_test'].first.call('run_test', args)
    Hash === raw ? raw : JSON.parse(raw)
  end

  def run_task(path, scope, timeout: nil)
    args = { 'path' => path, 'scope' => scope, 'location' => 'tmp' }
    args['timeout_seconds'] = timeout if timeout
    ScoutCoder.job(:run_test, nil, args).run
  end

  def seed!
    confine!
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'alpha.rb'), PASS)
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'beta.rb'), FAIL)
    File.write(File.join(@sandbox, 'share', 'test', 'integration', 'rt.rb'), PASS)
  end

  def confine!
    Dir.chdir(@sandbox)
    @agent = LLM::Agent.new
    @agent.integrate_workflow_path_kinds(ScoutCoder)
    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'test', 'task'))
    FileUtils.mkdir_p(File.join(@sandbox, 'share', 'test', 'integration'))
  end

  # ------------------------------------------------ item 11: file scope

  def test_run_test_file_scope_pass_and_fail
    confine!
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'alpha.rb'), PASS)
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'beta.rb'), FAIL)

    r = run_tool('task/alpha', 'file')
    assert_equal 1, r['count']
    assert_equal true, r['ok']
    assert_equal true, r['results'].first['passed']
    assert_equal 'clean_pass', r['results'].first['exit_class']
    assert_match(/1 tests?, 1 assertions?/, r['results'].first['summary'].to_s)

    f = run_tool('task/beta', 'file')
    assert_equal 1, f['count']
    assert_equal false, f['ok']
    assert_equal false, f['results'].first['passed']
    assert_equal true, f['results'].first['ran']
    assert_equal 'assertion_failure', f['results'].first['exit_class']
    assert_match(/assert/, f['results'].first['stdout'].to_s)
  end

  def test_run_test_file_scope_missing_target_is_parameter_exception
    confine!
    r = run_tool('task/nope', 'file')
    assert_match(/does not exist or is not a file/, r['exception'].to_s)
  end

  def test_run_test_file_scope_timeout_override
    confine!
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'slow.rb'),
               "require 'test/unit'\nclass Slow < Test::Unit::TestCase\n  def test_slow; sleep 30; end\nend\n")
    r = run_tool('task/slow', 'file', timeout: 1)
    assert_equal 'timeout', r['results'].first['exit_class']
    assert_equal true, r['results'].first['timed_out']
  end

  # ----------------------------------------- item 12: directory scope

  def test_run_test_directory_scope_aggregates
    seed!
    r = run_tool('task', 'directory')
    assert_equal 2, r['count']
    assert_equal false, r['ok']
    names = r['results'].collect { |x| File.basename(x['file']) }.sort
    assert_equal %w[alpha.rb beta.rb], names
    assert r['results'].all? { |x| x['ran'] }, 'both files must run and be reported'
  end

  # --------------------------------------------- item 13: suite scope

  def test_run_test_suite_scope_discovers_both_sides_and_empty_is_error
    seed!
    proj = File.join(@sandbox, 'test', 'ScoutCoder', 'tasks')
    FileUtils.mkdir_p(proj)
    File.write(File.join(proj, 'test_alpha.rb'), PASS)

    r = run_tool('.', 'suite')
    assert_equal 4, r['count']
    assert_equal false, r['ok'], 'one failing file (beta) => overall ok:false, all four reported'
    tails = r['results'].collect { |x| x['file'].sub(%r{\A#{Regexp.escape(@sandbox)}/}, '') }.sort
    assert_equal ['share/test/integration/rt.rb', 'share/test/task/alpha.rb',
                  'share/test/task/beta.rb', 'test/ScoutCoder/tasks/test_alpha.rb'], tails
  end

  def test_run_test_suite_scope_empty_is_error
    confine!
    r = run_tool('.', 'suite')
    assert_match(/no test files found/, r['exception'].to_s)
  end

  # ------------------------------------------------ the ScoutCoder task

  def test_run_test_task_file_scope
    confine!
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'alpha.rb'), PASS)
    r = run_task('task/alpha', 'file')
    assert_equal 1, r['count']
    assert_equal true, r['ok']
  end

  def test_run_test_task_directory_scope
    seed!
    r = run_task('task', 'directory')
    assert_equal 2, r['count']
    assert_equal false, r['ok']
  end

  def test_run_test_task_rejects_empty_discovery
    confine!
    error = assert_raise(ParameterException) { run_task('.', 'suite') }
    assert_match(/no test files found/, error.message)
  end

  def test_run_test_task_timeout_override
    confine!
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'slow.rb'),
               "require 'test/unit'\nclass Slow < Test::Unit::TestCase\n  def test_slow; sleep 30; end\nend\n")
    r = run_task('task/slow', 'file', timeout: 1)
    assert_equal 'timeout', r['results'].first['exit_class']
  end
end
