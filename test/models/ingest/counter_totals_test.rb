require "test_helper"

class Ingest::CounterTotalsTest < ActiveSupport::TestCase
  setup do
    @project = projects(:storefront)
    @issue = issues(:nomethod)
    @other = issues(:regressed)
    @hour = TimeSeries.align(Time.current, 1.hour)
    @chrome = [ @issue.id, "browser", IssueTagCount.value_digest("browser", "Chrome") ]
    @coupon = [ @issue.id, "coupon", IssueTagCount.value_digest("coupon", "FALL25") ]
  end

  test "sums events per issue, issue hour, project hour and tag value, and keeps last_seen_at as a maximum" do
    totals = Ingest::CounterTotals.new
    latest = @hour + 30.minutes
    add(totals, @issue, at: latest, new_user: true, tag_rows: [ @chrome, @coupon ])
    add(totals, @issue, at: @hour + 5.minutes, tag_rows: [ @chrome ])
    add(totals, @issue, at: @hour - 10.minutes, new_user: true)
    add(totals, @other, at: @hour + 1.minute, environment: "staging")
    totals.add_event(project_id: @project.id, environment: "production", occurred_at: @hour, received_at: @hour)

    assert_equal [ 3, 2, latest ], totals.issue(@issue.id).to_a
    assert_equal({ [ @issue.id, @hour ] => 2, [ @issue.id, @hour - 1.hour ] => 1, [ @other.id, @hour ] => 1 }, totals.issue_hours)
    assert_equal({ [ @project.id, "production", @hour ] => 3, [ @project.id, "production", @hour - 1.hour ] => 1,
                   [ @project.id, "staging", @hour ] => 1 }, totals.project_hours)
    assert_equal({ @chrome => 2, @coupon => 1 }, totals.tags)
  end

  test "the project hour is the hour received, the issue hour the hour occurred" do
    totals = Ingest::CounterTotals.new
    add(totals, @issue, at: @hour - 3.days, received_at: @hour + 5.minutes)

    assert_equal({ [ @issue.id, @hour - 3.days ] => 1 }, totals.issue_hours)
    assert_equal({ [ @project.id, "production", @hour ] => 1 }, totals.project_hours)
  end

  test "apply adds the totals to Postgres, with last_seen_at only moving forward" do
    @issue.update_columns(last_seen_at: @hour + 50.minutes)
    @other.update_columns(last_seen_at: @hour)
    totals = Ingest::CounterTotals.new
    add(totals, @issue, at: @hour + 10.minutes, new_user: true, tag_rows: [ @chrome ])
    add(totals, @issue, at: @hour + 20.minutes, tag_rows: [ @chrome, @coupon ])
    add(totals, @other, at: @hour + 40.minutes)

    assert_difference -> { @issue.reload.events_count } => 2, -> { @issue.reload.users_count } => 1,
                      -> { @other.reload.events_count } => 1,
                      -> { IssueHourlyCount.where(issue: @issue, hour: @hour).sum(:count) } => 2,
                      -> { ProjectHourlyCount.where(project: @project, environment: "production", hour: @hour).sum(:count) } => 3,
                      -> { issue_tag_counts(:nomethod_browser_chrome).reload.count } => 2,
                      -> { issue_tag_counts(:nomethod_coupon_fall25).reload.count } => 1 do
      totals.apply
    end
    assert_equal @hour + 50.minutes, @issue.reload.last_seen_at
    assert_equal @hour + 40.minutes, @other.reload.last_seen_at
  end

  test "apply runs in the ingest lock order, each statement locking its rows in key order" do
    totals = Ingest::CounterTotals.new
    add(totals, @issue, at: @hour, tag_rows: [ @chrome ])

    statements = capture_statements { totals.apply }

    assert_equal 4, statements.size
    assert_match(/\AWITH locked AS MATERIALIZED .* FROM issue_tag_counts .* ORDER BY .* FOR NO KEY UPDATE OF t \) UPDATE issue_tag_counts/,
                 statements[0])
    assert_match(/\AINSERT INTO issue_hourly_counts .* ORDER BY v.issue_id, v.hour ON CONFLICT/, statements[1])
    assert_match(/\AWITH locked AS MATERIALIZED \( SELECT id FROM issues .* ORDER BY id FOR NO KEY UPDATE \) UPDATE issues SET/,
                 statements[2])
    assert_match(/\AINSERT INTO project_hourly_counts .* ORDER BY v.project_id/, statements[3])
  end

  test "rows of issues, projects and tag values deleted meanwhile are dropped, not raised" do
    totals = Ingest::CounterTotals.new
    totals.add_event(project_id: 0, environment: "production", occurred_at: @hour, received_at: @hour, issue_id: 0,
                     tag_rows: [ [ 0, "browser", "gone" ] ])
    add(totals, @issue, at: @hour, tag_rows: [ [ @issue.id, "browser", "pruned" ], @chrome ])

    assert_difference -> { IssueHourlyCount.where(issue: @issue).sum(:count) } => 1, -> { ProjectHourlyCount.sum(:count) } => 1,
                      -> { IssueTagCount.sum(:count) } => 1 do
      assert_nothing_raised { totals.apply }
    end
    assert_not IssueHourlyCount.exists?(issue_id: 0)
    assert_not IssueTagCount.exists?(value_digest: %w[gone pruned])
  end

  test "chunks split the rows in lock order, the same way every time, and add up to the whole" do
    totals = Ingest::CounterTotals.new
    6.times { |i| add(totals, @issue, at: @hour - i.hours, tag_rows: [ @chrome ]) }
    add(totals, @other, at: @hour, tag_rows: [ @coupon ])

    chunks = totals.chunks(4)
    assert_equal [ 4, 4, 4, 4, 1 ], chunks.map(&:row_count) # 2 tag values, 7 issue hours, 2 issues, 6 project hours
    assert_equal totals.row_count, chunks.sum(&:row_count)
    assert_equal chunks.map(&:issue_hours), totals.chunks(4).map(&:issue_hours)
    assert_equal 2, chunks.first.tags.size, "tag values come first"
    assert_empty chunks.last.issue_hours

    assert_difference -> { @issue.reload.events_count } => 6, -> { IssueHourlyCount.where(issue: @issue).sum(:count) } => 6,
                      -> { issue_tag_counts(:nomethod_browser_chrome).reload.count } => 6 do
      chunks.each(&:apply)
    end
  end

  test "empty totals write nothing" do
    assert_predicate Ingest::CounterTotals.new, :empty?
    assert_empty capture_statements { Ingest::CounterTotals.new.apply }
  end

  private
    def add(totals, issue, at:, received_at: at, new_user: false, environment: "production", tag_rows: [])
      totals.add_event(project_id: issue.project_id, environment:, occurred_at: at, received_at:,
                       issue_id: issue.id, new_user:, tag_rows:)
    end

    def capture_statements(&block)
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      statements
    end
end
