require "test_helper"

class Ingest::StaleEventsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def backlog(seconds)
    Ingest::Backlog.new(shed_after: 120, resume_below: 30, source: FixedQueueLatency.new(seconds))
  end

  def unknown_backlog
    failing = Object.new
    def failing.seconds = raise("Redis down")
    Ingest::Backlog.new(shed_after: 120, resume_below: 30, source: failing, logger: ActiveSupport::Logger.new(nil))
  end

  def inbound_event_received(ago)
    inbound_events(:storefront_pending).dup.tap do
      it.update!(received_at: ago.ago, event_uuid: SecureRandom.uuid_v7, body: "{}")
    end
  end

  test "re-enqueues only inbound events older than ten minutes" do
    stale = inbound_events(:storefront_pending)
    stale.update_column(:received_at, 11.minutes.ago)
    fresh = stale.dup.tap { it.update!(received_at: Time.current, event_uuid: SecureRandom.uuid_v7, body: "{}") }

    assert_equal 1, Ingest::StaleEvents.new.requeue
    assert_enqueued_with(job: ProcessInboundEventJob, args: [ stale ])
    assert_enqueued_jobs 1
    assert fresh.persisted?
  end

  test "during a backlog, leaves events whose jobs are still waiting in the queue" do
    waiting = [ 11.minutes, 30.minutes, 64.minutes ].map { inbound_event_received(it) }
    lost = inbound_event_received(66.minutes)

    stale_events = Ingest::StaleEvents.new(backlog: backlog(1.hour.to_i))
    assert_equal 65.minutes, stale_events.stale_after
    assert_equal 1, stale_events.requeue
    assert_enqueued_with(job: ProcessInboundEventJob, args: [ lost ])
    assert_enqueued_jobs 1
    assert waiting.all?(&:persisted?)
  end

  test "without a backlog, lost jobs are requeued after the plain window" do
    lost = inbound_event_received(11.minutes)

    stale_events = Ingest::StaleEvents.new(backlog: backlog(2))
    assert_equal 10.minutes, stale_events.stale_after
    assert_equal 1, stale_events.requeue
    assert_enqueued_with(job: ProcessInboundEventJob, args: [ lost ])
  end

  test "while the last requeue's jobs are still waiting, does not requeue their events again" do
    with_memory_cache do
      freeze_time
      requeued = inbound_event_received(30.minutes)
      assert_equal 1, Ingest::StaleEvents.new(backlog: backlog(20.minutes.to_i)).requeue
      assert_enqueued_with(job: ProcessInboundEventJob, args: [ requeued ])

      travel 10.minutes
      clear_enqueued_jobs
      assert_equal 0, Ingest::StaleEvents.new(backlog: backlog(20.minutes.to_i)).requeue,
                   "received 40 minutes ago, but its requeued job has waited only 10 of the queue's 20 minutes"
      assert_enqueued_jobs 0
    end
  end

  test "a job lost during a backlog is requeued once the queue is past the last requeue" do
    with_memory_cache do
      freeze_time
      requeued = inbound_event_received(30.minutes)
      Ingest::StaleEvents.new(backlog: backlog(20.minutes.to_i)).requeue
      travel 10.minutes
      clear_enqueued_jobs
      requeued.destroy! # processed
      lost = inbound_event_received(20.minutes)

      assert_equal 1, Ingest::StaleEvents.new(backlog: backlog(9.minutes.to_i)).requeue
      assert_enqueued_with(job: ProcessInboundEventJob, args: [ lost ])
      assert_enqueued_jobs 1
    end
  end

  test "a lost job is requeued again once there is no backlog" do
    with_memory_cache do
      freeze_time
      lost = inbound_event_received(11.minutes)
      assert_equal 1, Ingest::StaleEvents.new(backlog: backlog(2)).requeue

      travel 10.minutes
      clear_enqueued_jobs
      inbound_events(:storefront_pending).update_column(:received_at, Time.current)
      assert_equal 1, Ingest::StaleEvents.new(backlog: backlog(2)).requeue
      assert_enqueued_with(job: ProcessInboundEventJob, args: [ lost ])
    end
  end

  test "an unknown queue latency keeps the plain window" do
    lost = inbound_event_received(11.minutes)

    stale_events = Ingest::StaleEvents.new(backlog: unknown_backlog)
    assert_equal 10.minutes, stale_events.stale_after
    assert_equal 1, stale_events.requeue
    assert_enqueued_with(job: ProcessInboundEventJob, args: [ lost ])
  end
end
