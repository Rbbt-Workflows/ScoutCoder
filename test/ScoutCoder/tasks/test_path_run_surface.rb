require 'test/unit'
require 'fileutils'
require 'json'
require 'tmpdir'
require File.expand_path('../../test_helper.rb', __dir__)

# Round 9 origin; ROUND-14 REWRITE (path_run consolidation): the retired
# test-runner task and its aggregated custom operation are gone, replaced
# by ONE `path_run` tool shared by the test_file and probe kinds (union
# contract {source, scope, timeout_seconds}, no declared defaults). This
# file exercises the test_file half of that union through the real engine
# tool wrapper installed on a confined agent, plus the union rejections
# that must fire BEFORE any execution. Runs against sandbox tmpdirs with
# the process CWD confined, so nothing touches the real share/test or
# test/ScoutCoder trees.
class TestPathRunSurface < Test::Unit::TestCase
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
    @sandbox = Dir.mktmpdir('r14-path-run')
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

  def run_tool(path, scope, timeout: nil, source: nil, location: 'tmp')
    args = { 'kind' => 'test_file', 'path' => path, 'scope' => scope }
    args['location'] = location if location
    args['timeout_seconds'] = timeout if timeout
    args['source'] = source if source
    raw = @agent.other_options[:tools]['path_run'].first.call('path_run', args)
    Hash === raw ? raw : JSON.parse(raw)
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

  # ------------------------------------------------ file scope

  def test_path_run_file_scope_pass_and_fail
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

  def test_path_run_file_scope_missing_target_is_parameter_exception
    confine!
    r = run_tool('task/nope', 'file')
    assert_match(/does not exist or is not a file/, r['exception'].to_s)
  end

  def test_path_run_reports_promoted_file_and_only_runs_it_on_explicit_retry
    confine!
    path = 'task/neko_python_tasks'
    project_file = @agent.resolve_path('test_file', path, 'project').to_s
    assert_equal File.join(@sandbox, 'test/ScoutCoder/tasks/test_neko_python_tasks.rb'), project_file
    FileUtils.mkdir_p(File.dirname(project_file))
    marker = File.join(@sandbox, 'ran')
    File.write(project_file, "File.write(#{marker.inspect}, 'yes')\n" + PASS)

    missing = run_tool(path, 'file', location: nil)
    assert_match(/location="project"/, missing.fetch('exception'))
    assert_false File.exist?(marker)

    retry_result = run_tool(path, 'file', location: 'project')
    assert_equal true, retry_result['ok']
    assert_equal project_file, retry_result['target']
    assert_equal 'yes', File.read(marker)
  end

  def test_path_run_uses_requested_copy_when_both_exist
    seed!
    promoted = @agent.resolve_path('test_file', 'task/alpha', 'project').to_s
    assert_equal File.join(@sandbox, 'test/ScoutCoder/tasks/test_alpha.rb'), promoted
    FileUtils.mkdir_p(File.dirname(promoted))
    File.write(promoted, FAIL)
    assert_equal true, run_tool('task/alpha', 'file')['ok']
    assert_equal false, run_tool('task/alpha', 'file', location: 'project')['ok']
  end

  def test_path_run_file_scope_timeout_override
    confine!
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'slow.rb'),
               "require 'test/unit'\nclass Slow < Test::Unit::TestCase\n  def test_slow; sleep 30; end\nend\n")
    r = run_tool('task/slow', 'file', timeout: 1)
    assert_equal 'timeout', r['results'].first['exit_class']
    assert_equal true, r['results'].first['timed_out']
  end

  # omitted timeout_seconds reaches the runner as nil; the runner's own
  # per-scope default applies (round-14 receipt-verified union contract).
  def test_path_run_omitted_timeout_uses_runner_default
    confine!
    File.write(File.join(@sandbox, 'share', 'test', 'task', 'alpha.rb'), PASS)
    r = run_tool('task/alpha', 'file')
    assert_equal 1, r['count']
    assert_equal 'file', r['scope']
    assert_equal false, r['results'].first['timed_out'], 'default file timeout must still bound the child run'
  end

  # timeout bounds are enforced BEFORE any child process spawns.
  def test_path_run_timeout_bounds_rejected_before_spawn
    confine!
    [0, -5, ScoutCoder::TestFileSupport::MAX_TIMEOUT + 1, 'soon'].each do |bad|
      r = run_tool('task/none', 'file', timeout: bad)
      assert r.key?('exception'), "bounds violation must fail: #{bad.inspect} -> #{r.inspect}"
      assert_match(/timeout_seconds/, r['exception'].to_s)
    end
  end

  # ---------------------------------------- directory scope

  def test_path_run_directory_scope_aggregates
    seed!
    r = run_tool('task', 'directory')
    assert_equal 2, r['count']
    assert_equal false, r['ok']
    names = r['results'].collect { |x| File.basename(x['file']) }.sort
    assert_equal %w[alpha.rb beta.rb], names
    assert r['results'].all? { |x| x['ran'] }, 'both files must run and be reported'
  end

  # --------------------------------------------- suite scope

  def test_path_run_suite_scope_discovers_both_sides
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

  def test_path_run_suite_scope_empty_is_error
    confine!
    r = run_tool('.', 'suite')
    assert_match(/no test files found/, r['exception'].to_s)
  end

  # ------------------------------- union rejections (round 14)

  # source belongs to kind=probe; test_file must reject it BEFORE any
  # execution — an agent must never believe supplied source was tested.
  def test_path_run_rejects_source_for_test_file_before_execution
    confine!
    file = File.join(@sandbox, 'share', 'test', 'task', 'alpha.rb')
    File.write(file, PASS)
    r = run_tool('task/alpha', 'file', source: "puts 'INJECTED'")
    assert_match(/source is not applicable to the test_file kind/, r['exception'].to_s)
    refute File.read(file).include?('INJECTED'),
           'the supplied source must never be written into the test file'
    assert_equal PASS, File.read(file), 'the existing test file must be byte-identical'
  end

  # scope belongs to kind=test_file; probe must reject it before execution.
  def test_path_run_rejects_scope_for_probe_before_execution
    confine!
    args = { 'kind' => 'probe', 'path' => 'never_runs', 'scope' => 'file',
             'source' => "File.write(File.join(#{@sandbox.inspect}, 'canary'), 'RAN')" }
    raw = @agent.other_options[:tools]['path_run'].first.call('path_run', args)
    r = Hash === raw ? raw : JSON.parse(raw)
    assert_match(/scope is not applicable to the probe kind/, r['exception'].to_s)
    refute File.exist?(File.join(@sandbox, 'canary')),
           'the probe must not execute when scope is supplied'
  end

  # Probe-half positive coverage (create-and-run, save/syntax/execute
  # separation, source-retained-after-failure) lives in test_path_kinds.rb
  # probe section, which drives the SAME path_run tool against a sandboxed
  # probe-kind copy — nothing here may write into the real share/probes.
end