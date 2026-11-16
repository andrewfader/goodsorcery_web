# Atomic upserts for one event's per-issue rows: tag value counts and the
# affected-user row, then (slow path only) the issue's hourly count.
# Multi-row upserts are sorted so concurrent transactions lock rows in the
# same order. The project hour, and on the fast path the issue hour, are
# counted through the counters (Ingest::CounterTotals), which write them in
# the same lock order.
#
# With buffer_tags (the counter buffer), only tag values the issue hasn't
# seen yet are inserted here; the increments of values it already has are
# left in #buffered_tag_rows, as (issue_id, key, value_digest) triples, for
# the buffer. Their rows are then never locked by the event's transaction.
class Ingest::Rollups
  USER_ON_DUPLICATE = <<~SQL.squish.freeze
    events_count = issue_users.events_count + 1,
    first_seen_at = LEAST(issue_users.first_seen_at, EXCLUDED.first_seen_at),
    last_seen_at = GREATEST(issue_users.last_seen_at, EXCLUDED.last_seen_at),
    identity_digests = ARRAY(SELECT DISTINCT unnest(issue_users.identity_digests || EXCLUDED.identity_digests) ORDER BY 1)
  SQL

  attr_reader :buffered_tag_rows

  def initialize(issue_id, project, event, buffer_tags: false)
    @issue_id, @project, @event, @buffer_tags = issue_id, project, event, buffer_tags
    @buffered_tag_rows = []
  end

  # Tag and affected-user rows. Returns true when this is the first event of
  # this user for the issue.
  def increment_issue
    increment_tags
    increment_user
  end

  # Taken after the tag and user rows and before the issue row.
  def increment_issue_hour
    IssueHourlyCount.upsert({ issue_id: @issue_id, hour: TimeSeries.align(@event.occurred_at, 1.hour), count: 1 },
                            on_duplicate: Arel.sql("count = issue_hourly_counts.count + 1"), record_timestamps: false)
  end

  private

    def increment_tags
      tag_rows = Ingest::TagRows.new(@issue_id, @event.tags)
      rows = @buffer_tags ? buffer_stored(tag_rows) : tag_rows.to_a
      return if rows.empty?

      IssueTagCount.upsert_all(rows, on_duplicate: Arel.sql("count = issue_tag_counts.count + 1"), record_timestamps: false)
    end

    # Leaves the stored rows to the buffer; returns the rows to insert.
    def buffer_stored(tag_rows)
      @buffered_tag_rows = tag_rows.stored_rows.map { |row| row.values_at(:issue_id, :key, :value_digest) }
      tag_rows.new_rows
    end

    def increment_user
      return false unless @event.user_identity.present?

      result = IssueUser.upsert(user_row, on_duplicate: Arel.sql(USER_ON_DUPLICATE),
                                returning: Arel.sql("(xmax = 0) AS inserted"), record_timestamps: false)
      result.rows.dig(0, 0) == true
    end

    def user_row
      identity = @event.user_identity
      { issue_id: @issue_id, project_id: @project.id, user_digest: identity.primary_digest,
        identity_digests: identity.digests, events_count: 1, first_seen_at: @event.occurred_at, last_seen_at: @event.occurred_at }
    end
end
