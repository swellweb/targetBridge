require 'json'
require 'open3'
require 'time'

module GitHubBacklogGate
  REPOSITORY = 'swellweb/targetBridge'.freeze
  THRESHOLD = 10

  def self.evaluate(pr_count:, issue_count:)
    counts = [pr_count, issue_count]
    raise ArgumentError, 'Counts must be non-negative integers' unless
      counts.all? { |count| count.is_a?(Integer) && count >= 0 }

    { repository: REPOSITORY, new_prs: pr_count, new_issues: issue_count,
      threshold_prs: THRESHOLD, threshold_issues: THRESHOLD,
      ready: pr_count >= THRESHOLD && issue_count >= THRESHOLD }
  end

  def self.queries(baseline)
    timestamp = Time.iso8601(baseline).utc.iso8601
    raise ArgumentError, 'Baseline must not be in the future' if Time.iso8601(timestamp) > Time.now

    %w[pr issue].map do |kind|
      "repo:#{REPOSITORY} is:#{kind} created:>#{timestamp}"
    end
  end

  def self.count(query)
    # Count only: do not request titles, bodies, comments, diffs or search nodes.
    graphql = "query { search(query: #{JSON.generate(query)}, type: ISSUE) { issueCount } }"
    output, error, status = Open3.capture3('gh', 'api', 'graphql', '-f', "query=#{graphql}")
    raise "GitHub count request failed: #{error.strip}" unless status.success?

    response = JSON.parse(output)
    raise 'GitHub returned GraphQL errors' if response.key?('errors')

    result = response.dig('data', 'search', 'issueCount')
    raise 'GitHub did not return a valid count' unless result.is_a?(Integer) && result >= 0

    result
  end

  def self.run(baseline)
    pr_query, issue_query = queries(baseline)
    evaluate(pr_count: count(pr_query), issue_count: count(issue_query))
      .merge(baseline: Time.iso8601(baseline).utc.iso8601)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    abort "Usage: ruby #{$PROGRAM_NAME} BASELINE_ISO8601" unless ARGV.length == 1
    puts JSON.pretty_generate(GitHubBacklogGate.run(ARGV.first))
  rescue StandardError => error
    warn error.message
    exit 2
  end
end
