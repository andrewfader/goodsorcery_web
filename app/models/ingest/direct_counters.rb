# Ingest counters without a buffer: development, test, and production with
# GOODSORCERY_COUNTER_BUFFER=0 (docs/ARCHITECTURE.md §2.5.1). Each event's
# counts are written inside the processor's transaction, as its last
# statements, so they keep the ingest lock order and commit with the event.
# Tag values are counted by Ingest::Rollups in the transaction, as before.
class Ingest::DirectCounters
  # Tag increments stay in Ingest::Rollups' upsert.
  def buffered? = false

  # The occurrence id only matters to the buffer's idempotent add.
  def add_event(occurrence_id: nil, **counts)
    Ingest::CounterTotals.for_event(**counts).apply
  end
end
