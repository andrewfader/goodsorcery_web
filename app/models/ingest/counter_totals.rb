# Ingest counters summed over one or more events, and added to Postgres in
# a few multi-row statements (docs/ARCHITECTURE.md §2.5.1):
#
# - issue_tag_counts of tag values already stored for their issue;
# - issue_hourly_counts;
# - issues: events_count, users_count and last_seen_at (a maximum);
# - project_hourly_counts.
#
# Statements run in that order, the ingest lock order, and each locks its
# rows in key order (an explicit ORDER BY … FOR NO KEY UPDATE, or an INSERT
# from sorted rows), so they never deadlock with a processor's transaction
# or another flush. Rows of issues, projects or tag values deleted meanwhile
# are dropped. Holds ids, hours, environment names, tag keys, tag value
# digests and numbers only: never a tag value.
#
#   totals = Ingest::CounterTotals.new
#   totals.add_event(project_id: 1, environment: "production", occurred_at: 1.minute.ago, received_at: Time.current,
#                    issue_id: 7, new_user: true, tag_rows: [ [ 7, "environment", "3f9a…" ] ])
#   totals.apply
class Ingest::CounterTotals
  IssueCount = Struct.new(:events, :users, :last_seen_at)

  # The tables in lock order.
  TABLES = %i[tags issue_hours issues project_hours].freeze

  # Only rows that exist are counted: a tag value pruned by retention since
  # the event was buffered loses its increment.
  TAGS_SQL = <<~SQL.squish.freeze
    WITH locked AS MATERIALIZED (
      SELECT t.issue_id, t.key, t.value_digest, v.count
      FROM issue_tag_counts t
      JOIN unnest(CAST(ARRAY[:issue_ids] AS bigint[]), CAST(ARRAY[:tag_keys] AS varchar[]),
                  CAST(ARRAY[:digests] AS varchar[]), CAST(ARRAY[:counts] AS bigint[])) AS v(issue_id, key, value_digest, count)
        ON t.issue_id = v.issue_id AND t.key = v.key AND t.value_digest = v.value_digest
      ORDER BY t.issue_id, t.key COLLATE "C", t.value_digest COLLATE "C"
      FOR NO KEY UPDATE OF t
    )
    UPDATE issue_tag_counts SET count = issue_tag_counts.count + locked.count
    FROM locked
    WHERE issue_tag_counts.issue_id = locked.issue_id AND issue_tag_counts.key = locked.key
      AND issue_tag_counts.value_digest = locked.value_digest
  SQL

  ISSUE_HOURS_SQL = <<~SQL.squish.freeze
    INSERT INTO issue_hourly_counts (issue_id, hour, count)
    SELECT v.issue_id, v.hour, v.count
    FROM unnest(CAST(ARRAY[:issue_ids] AS bigint[]), CAST(ARRAY[:hours] AS timestamp[]), CAST(ARRAY[:counts] AS integer[]))
      AS v(issue_id, hour, count)
    JOIN issues ON issues.id = v.issue_id
    ORDER BY v.issue_id, v.hour
    ON CONFLICT (issue_id, hour) DO UPDATE SET count = issue_hourly_counts.count + EXCLUDED.count
  SQL

  # The issue rows are locked in id order first, so the order doesn't depend
  # on the join the planner picks for the UPDATE.
  ISSUES_SQL = <<~SQL.squish.freeze
    WITH locked AS MATERIALIZED (
      SELECT id FROM issues WHERE id = ANY(CAST(ARRAY[:ids] AS bigint[])) ORDER BY id FOR NO KEY UPDATE
    )
    UPDATE issues SET
      events_count = issues.events_count + v.events,
      users_count  = issues.users_count + v.users,
      last_seen_at = GREATEST(issues.last_seen_at, v.last_seen_at),
      updated_at   = CAST(:now AS timestamp)
    FROM locked
    JOIN unnest(CAST(ARRAY[:ids] AS bigint[]), CAST(ARRAY[:events] AS bigint[]), CAST(ARRAY[:users] AS integer[]),
                CAST(ARRAY[:last_seen] AS timestamp[])) AS v(id, events, users, last_seen_at) ON v.id = locked.id
    WHERE issues.id = locked.id
  SQL

  PROJECT_HOURS_SQL = <<~SQL.squish.freeze
    INSERT INTO project_hourly_counts (project_id, environment, hour, count)
    SELECT v.project_id, v.environment, v.hour, v.count
    FROM unnest(CAST(ARRAY[:project_ids] AS bigint[]), CAST(ARRAY[:environments] AS varchar[]),
                CAST(ARRAY[:hours] AS timestamp[]), CAST(ARRAY[:counts] AS bigint[])) AS v(project_id, environment, hour, count)
    JOIN projects ON projects.id = v.project_id
    ORDER BY v.project_id, v.environment COLLATE "C", v.hour
    ON CONFLICT (project_id, environment, hour) DO UPDATE SET count = project_hourly_counts.count + EXCLUDED.count
  SQL

  # { [issue_id, key, value_digest] => count }, { [issue_id, hour] => count }, { issue_id => IssueCount },
  # { [project_id, environment, hour] => count }
  attr_reader :tags, :issue_hours, :issues, :project_hours

  def self.for_event(...) = new.add_event(...)

  # Rebuilds totals from #sorted_rows entries.
  def self.from_rows(rows)
    new.tap do |totals|
      rows.each { |table, key, value| totals.public_send(table)[key] = value }
    end
  end

  def initialize
    @tags = Hash.new(0)
    @issue_hours = Hash.new(0)
    @issues = {}
    @project_hours = Hash.new(0)
  end

  # Counts one event in its project's hour, its stored tag values
  # (tag_rows: [issue_id, key, value_digest] triples) and, given an
  # issue_id, the issue's counters and hour. Returns self. The project hour
  # is the hour the event was received, since the monthly quota sums those
  # rows and a client can backdate occurred_at; the issue hour is when it
  # occurred.
  def add_event(project_id:, environment:, occurred_at:, received_at:, issue_id: nil, new_user: false, tag_rows: [])
    project_hours[[ project_id, environment, TimeSeries.align(received_at, 1.hour) ]] += 1
    tag_rows.each { |row| tags[row] += 1 }
    add_issue_event(issue_id, occurred_at, new_user) if issue_id
    self
  end

  # The (created on first use) counters of one issue.
  def issue(issue_id) = issues[issue_id] ||= IssueCount.new(0, 0, nil)

  def empty? = TABLES.all? { |table| public_send(table).empty? }

  def issue_ids = (issues.keys + issue_hours.keys.map(&:first) + tags.keys.map(&:first)).uniq

  def project_ids = project_hours.keys.map(&:first).uniq

  def row_count = TABLES.sum { |table| public_send(table).size }

  # Splits the rows, in lock order and sorted, into totals of at most
  # +rows+ rows each. The same totals always split the same way.
  def chunks(rows)
    sorted_rows.each_slice(rows).map { |slice| self.class.from_rows(slice) }
  end

  def apply
    add_tags if tags.any?
    add_issue_hours if issue_hours.any?
    add_issue_counts if issues.any?
    add_project_hours if project_hours.any?
  end

  private
    def add_issue_event(issue_id, occurred_at, new_user)
      issue_hours[[ issue_id, TimeSeries.align(occurred_at, 1.hour) ]] += 1
      counts = issue(issue_id)
      counts.events += 1
      counts.users += 1 if new_user
      counts.last_seen_at = [ counts.last_seen_at, occurred_at ].compact.max
    end

    def sorted_rows
      TABLES.flat_map do |table|
        public_send(table).sort_by(&:first).map { |key, value| [ table, key, value ] }
      end
    end

    # Each statement's arrays, from the table's sorted rows.
    def columns(table) = public_send(table).sort_by(&:first).map { |key, value| [ *key, *value ] }.transpose

    def add_tags
      issue_ids, tag_keys, digests, counts = columns(:tags)
      execute(TAGS_SQL, issue_ids:, tag_keys:, digests:, counts:)
    end

    def add_issue_hours
      issue_ids, hours, counts = columns(:issue_hours)
      execute(ISSUE_HOURS_SQL, issue_ids:, hours:, counts:)
    end

    def add_issue_counts
      ids, events, users, last_seen = columns(:issues)
      execute(ISSUES_SQL, ids:, events:, users:, last_seen:, now: Time.current)
    end

    def add_project_hours
      project_ids, environments, hours, counts = columns(:project_hours)
      execute(PROJECT_HOURS_SQL, project_ids:, environments:, hours:, counts:)
    end

    # #update (unlike #exec_update) clears the query cache, which jobs run with.
    def execute(sql, values)
      ApplicationRecord.connection.update(ApplicationRecord.sanitize_sql_array([ sql, values ]), "Ingest counters")
    end
end
