# Turns one stored InboundEvent into an occurrence of a (new or existing)
# issue, with all counters and rollups, in a single short transaction
# (ARCHITECTURE.md §2.5). Live updates are announced, and alerts for the
# transitions the event caused flagged (§11.4), after commit.
#
# An event that can't change its issue's state (Ingest::IssueTally#settled?)
# takes the fast path: the issue row and the hourly rows aren't touched in
# the transaction, and their counts go to the counters
# (Ingest::CounterBuffer, or Ingest::DirectCounters without one). The rest
# take the slow path through the locking counter UPDATE. With the buffer,
# the increments of tag values the issue already has go there too, on both
# paths.
class Ingest::Processor
  # Occurrence trimming runs for one event in TRIM_EVERY, drawn at random:
  # the fast path has no fresh events_count to take a modulo of, and a draw
  # trims as often on average with no shared state (TrimOccurrencesJob is
  # idempotent, and CapStoredOccurrencesJob caps each app anyway).
  TRIM_EVERY = 50

  attr_reader :inbound_event, :project

  def initialize(inbound_event, counters: Ingest::CounterBuffer.current)
    @inbound_event = inbound_event
    @project = inbound_event.project
    @counters = counters
  end

  # Returns the Issue, or nil when the event was discarded (malformed body or
  # duplicate event id). After the slow path it is the updated row; after the
  # fast path, the partial snapshot read before the event (no counters).
  def process
    ApplicationRecord.uncached { record(build_event) }
  rescue Ingest::MalformedPayload
    discard("malformed")
  rescue ArgumentError => error
    # Backstop for a value Postgres cannot store ("string contains null
    # byte"), so such an event is dropped instead of retried forever.
    raise unless error.message.include?("null byte")

    discard("unstorable")
  end

  private
    def build_event
      Ingest::Event.from_json(inbound_event.body, project:, environment: inbound_event.environment,
                                                  received_at: inbound_event.received_at)
    end

    def record(event)
      tally = Ingest::IssueTally.new(project, event).prepare
      issue = ApplicationRecord.transaction { record_occurrence(tally, event) }
      return discard("duplicate") unless issue

      announce(issue, created: tally.created?)
      flag_alerts(issue, created: tally.created?)
      issue
    end

    # Locks are taken in one order by every processor and by the counter
    # flush: tag and affected-user rows, the issue's hourly row, the issue
    # row, and last the project's hourly row, which every event of the
    # project, environment and hour needs, so it is held only until COMMIT.
    def record_occurrence(tally, event)
      issue_id = tally.find_or_create_issue_id
      raise ActiveRecord::Rollback unless insert_occurrence(issue_id, event)

      rollups = Ingest::Rollups.new(issue_id, project, event, buffer_tags: @counters.buffered?)
      tally.settled? ? count_settled(tally, rollups, event) : count_transition(tally, rollups, event)
    end

    # Fast path: no lock on the issue row; the issue's counters and both
    # hourly rows go to the counters. Returns the snapshot, which reports no
    # transition.
    def count_settled(tally, rollups, event)
      new_user = rollups.increment_issue
      inbound_event.delete
      @counters.add_event(**event_counts(event, rollups), issue_id: tally.issue_id, new_user:)
      tally.snapshot
    end

    # Slow path: the locking counter UPDATE decides the transition and
    # counts the issue; only the project's hourly row (and, with the buffer,
    # the stored tag values) goes to the counters.
    def count_transition(tally, rollups, event)
      new_user = rollups.increment_issue
      rollups.increment_issue_hour
      issue = tally.count(new_user:)
      record_milestones(issue)
      project.record_first_event(runtime_label: event.runtime_label, at: event.occurred_at) if tally.created?
      inbound_event.delete
      @counters.add_event(**event_counts(event, rollups))
      issue
    end

    # The occurrence id makes the buffer's add idempotent (a retried or
    # fallen-back add counts once); it is never stored as a counter.
    def event_counts(event, rollups)
      { project_id: project.id, environment: event.environment, occurred_at: event.occurred_at,
        received_at: inbound_event.received_at, occurrence_id: @occurrence_id, tag_rows: rollups.buffered_tag_rows }
    end

    # The new occurrence id, or nil for a duplicate event id.
    def insert_occurrence(issue_id, event)
      result = Occurrence.insert(occurrence_attributes(issue_id, event), unique_by: %i[project_id uuid], returning: %i[id])
      @occurrence_id = result.rows.first&.first
    end

    def occurrence_attributes(issue_id, event)
      { issue_id:, project_id: project.id, uuid: inbound_event.event_uuid, occurred_at: event.occurred_at,
        received_at: inbound_event.received_at, environment: event.environment, release: event.release,
        level: event.level, user_digest: event.user_identity.primary_digest, payload: event.to_payload_json }
    end

    # System entries for the issue's timeline, written while the issue row is
    # still locked and before the project's hourly row.
    def record_milestones(issue)
      IssueActivity.create!(issue:, kind: "regressed") if issue.previous_status == "resolved"
      IssueActivity.create!(issue:, kind: "reached_production") if issue.just_reached_production
    end

    def announce(issue, created:)
      issue.broadcast_changes_later(created:)
      project.broadcast_changes_later
      TrimOccurrencesJob.perform_later(issue) if trim_due?
    end

    def trim_due? = Random.rand(TRIM_EVERY).zero?

    # Read from what the counter UPDATE already returned (on the fast path,
    # the snapshot, which reports none), so an ordinary event of an existing
    # issue costs nothing here. The job gets ids and the kind.
    def flag_alerts(issue, created:)
      IssueAlert.transitions(issue, created:).each do |kind|
        IssueAlertJob.perform_later(issue.id, kind, @occurrence_id)
      end
    end

    def discard(reason)
      InboundEvent.where(id: inbound_event.id).delete_all
      Rails.logger.info { "Ingest discarded inbound event #{inbound_event.id} (#{reason})" }
      nil
    end
end
