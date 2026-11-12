require 'minitest/autorun'
require_relative 'github_backlog_gate'

class GitHubBacklogGateTest < Minitest::Test
  def test_both_thresholds_are_required
    [[0, 0], [10, 0], [0, 10], [9, 10], [10, 9], [100, 9], [9, 100]].each do |prs, issues|
      refute GitHubBacklogGate.evaluate(pr_count: prs, issue_count: issues).fetch(:ready)
    end
  end

  def test_ready_at_exact_threshold_and_above
    [[10, 10], [11, 10], [10, 11]].each do |prs, issues|
      assert GitHubBacklogGate.evaluate(pr_count: prs, issue_count: issues).fetch(:ready)
    end
  end

  def test_counts_are_preserved
    result = GitHubBacklogGate.evaluate(pr_count: 12, issue_count: 8)
    assert_equal 12, result[:new_prs]
    assert_equal 8, result[:new_issues]
  end

  def test_invalid_counts_fail_closed
    [-1, nil, '10', 10.5].each do |invalid|
      assert_raises(ArgumentError) { GitHubBacklogGate.evaluate(pr_count: invalid, issue_count: 10) }
      assert_raises(ArgumentError) { GitHubBacklogGate.evaluate(pr_count: 10, issue_count: invalid) }
    end
  end

  def test_queries_exclude_old_items_but_include_all_states
    prs, issues = GitHubBacklogGate.queries('2026-11-12T09:00:00+01:00')
    assert_equal 'repo:swellweb/targetBridge is:pr created:>2026-11-12T08:00:00Z', prs
    assert_equal 'repo:swellweb/targetBridge is:issue created:>2026-11-12T08:00:00Z', issues
  end

  def test_invalid_or_future_baselines_are_rejected
    assert_raises(ArgumentError) { GitHubBacklogGate.queries('not-a-date') }
    assert_raises(ArgumentError) { GitHubBacklogGate.queries((Time.now + 3600).iso8601) }
  end
end
