# Inbound events accepted but not processed within InboundEvent.stale's window,
# for example after a Redis outage lost their jobs.
#
# While the ingest queue is behind, an event's job can simply still be
# waiting, and requeueing it would add a duplicate job per waiting event on
# every run and fill Redis. Two guards, both reading the queue latency
# (Ingest::Backlog):
#
# - The window grows to the latency plus LATENCY_MARGIN, so a first run
#   during a backlog leaves events whose original job is still queued.
# - A run is skipped while the jobs of the last requeue are still waiting
#   (the latency is at least the time since then). Requeued jobs wait at the
#   back of the queue, but their events keep their received_at, so the window
#   alone would requeue them again on every run.
#
# The last requeue's time (a timestamp only) is kept in Rails.cache. An
# evicted or expired entry only costs one extra requeue; duplicates are
# harmless, since a processed event is discarded. A job lost while a backlog
# lasts is requeued once the queue has worked through the previous batch.
# An unknown latency keeps the plain window and never skips.
class Ingest::StaleEvents
  LATENCY_MARGIN = 5.minutes
  LAST_REQUEUE_KEY = "ingest:stale_events:last_requeue_at".freeze

  def initialize(backlog: Ingest::Backlog.current)
    @backlog = backlog
  end

  # Enqueues a processing job (GlobalID only) per stale event; returns the
  # count, 0 when the last requeue's jobs are still waiting.
  def requeue
    latency = @backlog.latency
    return 0 if last_requeue_waiting?(latency)

    count = InboundEvent.stale(stale_after(latency)).select(:id).find_each.count do |inbound_event|
      ProcessInboundEventJob.perform_later(inbound_event)
    end
    remember_requeue if count.positive?
    count
  end

  def stale_after(latency = @backlog.latency)
    return InboundEvent::STALE_AFTER if latency.nil?

    [ InboundEvent::STALE_AFTER, latency.seconds + LATENCY_MARGIN ].max
  end

  private
    # The oldest waiting job has waited at least as long as it has been since
    # the last requeue finished, so some of those jobs are still queued.
    def last_requeue_waiting?(latency)
      requeued_at = Rails.cache.read(LAST_REQUEUE_KEY)
      return false if latency.nil? || requeued_at.nil?

      latency >= Time.current.to_f - requeued_at
    end

    # After the last enqueue, so the whole batch is behind this time.
    def remember_requeue
      Rails.cache.write(LAST_REQUEUE_KEY, Time.current.to_f, expires_in: Ingest::Retention::UNPROCESSED_TTL)
    end
end
