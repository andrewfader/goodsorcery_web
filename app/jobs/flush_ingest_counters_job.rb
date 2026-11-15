# Every 10 seconds (config/schedule.yml, a six-field cron line): adds the
# ingest counters buffered in Valkey to Postgres (Ingest::CounterBuffer,
# docs/ARCHITECTURE.md §2.5.2). Does nothing without a configured store.
#
# On its own queue, so it never waits behind an ingest backlog. Not retried:
# the next run, seconds later, picks up whatever this one left behind, and
# Sidekiq retries would only pile up copies of it.
class FlushIngestCountersJob < ApplicationJob
  queue_as :counters
  sidekiq_options retry: false

  def perform
    Ingest::CounterBuffer.configured&.flush
  end
end
