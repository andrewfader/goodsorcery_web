require "test_helper"
require_relative "ingest_test_support"
require_relative "../../test_helpers/counter_buffer_test_helper"

# Several processors working on events of one issue at once, as Sidekiq
# threads do during an error storm. Runs outside a test transaction so each
# thread commits on its own connection.
class Ingest::ConcurrentProcessingTest < ActiveSupport::TestCase
  include IngestTestSupport
  include CounterBufferTestHelper

  self.use_transactional_tests = false

  THREADS = 4
  EVENTS = 40

  setup do
    @project = accounts(:acme).projects.create!(name: "Concurrency #{SecureRandom.hex(4)}")
    @key = @project.api_keys.first
  end

  teardown do
    Project.where(id: @project.id).delete_all # rows cascade in the database
    clear_counter_store
  end

  test "events of one issue process concurrently without deadlocks" do
    inbound = Array.new(EVENTS) { inbound_event_for(minimal_json, key: @key, event_uuid: SecureRandom.uuid) }

    errors = process_concurrently(inbound)

    assert_empty errors.map { |error| error.class.name }
    issue = @project.issues.sole
    assert_equal EVENTS, issue.events_count
    assert_equal EVENTS, ProjectHourlyCount.where(project: @project).sum(:count)
    assert_equal EVENTS, IssueHourlyCount.where(issue:).sum(:count)
    assert_not InboundEvent.exists?(project_id: @project.id)
  end

  test "a staging issue reaches production exactly once under concurrent production events" do
    staging_key = @project.api_keys.find_by!(environment: "staging")
    Ingest::Processor.new(inbound_event_for(minimal_json, key: staging_key, event_uuid: SecureRandom.uuid)).process
    inbound = Array.new(EVENTS) { inbound_event_for(minimal_json, key: @key, event_uuid: SecureRandom.uuid) }

    errors = process_concurrently(inbound)

    assert_empty errors.map { |error| error.class.name }
    issue = @project.issues.sole
    assert_equal EVENTS + 1, issue.events_count
    assert_predicate issue, :reached_production?
    assert_equal 1, issue.activities.where(kind: "reached_production").count
    assert_equal 1, alert_jobs_for(issue, "reached_production").size, "flagged once, by the event that stamped it"
  end

  test "buffered events on both paths and flushes running at once count every event and tag value exactly once" do
    buffer = counter_buffer(chunk_rows: 2)
    staging_key = @project.api_keys.find_by!(environment: "staging")
    Ingest::Processor.new(inbound_event_for(minimal_json, key: @key, event_uuid: SecureRandom.uuid)).process
    # Every other event is from staging: the first ones take the slow path
    # (a new environment) and insert the new tag value, the rest are buffered.
    inbound = Array.new(EVENTS) { |i| inbound_event_for(minimal_json, key: i.odd? ? staging_key : @key, event_uuid: SecureRandom.uuid) }

    done = false
    flusher = Thread.new { flush_until(buffer) { done } }
    errors = process_concurrently(inbound, counters: buffer)
    done = true
    flusher.join
    with_connection { counter_buffer.flush }

    assert_empty errors.map { |error| error.class.name }
    issue = @project.issues.sole
    assert_equal EVENTS + 1, issue.events_count
    assert_equal EVENTS + 1, ProjectHourlyCount.where(project: @project).sum(:count)
    assert_equal EVENTS + 1, IssueHourlyCount.where(issue:).sum(:count)
    assert_equal({ "production" => EVENTS / 2 + 1, "staging" => EVENTS / 2 },
                 IssueTagCount.where(issue:, key: "environment").to_h { [ it.value, it.count ] })
  end

  test "flushes started at once apply the buffered counts once" do
    buffer = counter_buffer
    issue_id = Ingest::Processor.new(inbound_event_for(minimal_json, key: @key, event_uuid: SecureRandom.uuid)).process.id
    EVENTS.times do |i|
      buffer.add_event(project_id: @project.id, environment: "production", occurred_at: Time.current, received_at: Time.current,
                       issue_id:, occurrence_id: i)
    end

    results = Array.new(THREADS) { Thread.new { with_connection { counter_buffer.flush } } }.map(&:value)

    assert_equal EVENTS + 1, Issue.find(issue_id).events_count
    assert_equal 1, results.compact.sum, "one run applied the batch: #{results.inspect}"
  end

  private
    def with_connection(&) = ActiveRecord::Base.connection_pool.with_connection(&)

    def flush_until(buffer)
      with_connection do
        until yield
          buffer.flush
          sleep 0.005
        end
      end
    end

    # The test adapter (config/environments/test.rb) keeps what every thread enqueued.
    def alert_jobs_for(issue, kind)
      IssueAlertJob.queue_adapter.enqueued_jobs.select do |job|
        job["job_class"] == "IssueAlertJob" && job["arguments"].first(2) == [ issue.id, kind ]
      end
    end

    def process_concurrently(inbound, counters: nil)
      errors = Queue.new
      threads = inbound.each_slice(EVENTS / THREADS).map do |slice|
        Thread.new { process_all(slice, errors, counters) }
      end
      threads.each(&:join)
      Array.new(errors.size) { errors.pop }
    end

    def process_all(inbound_events, errors, counters)
      with_connection do
        inbound_events.each { |inbound_event| Ingest::Processor.new(inbound_event, **{ counters: }.compact).process }
      end
    rescue StandardError => error
      errors << error
    end
end
