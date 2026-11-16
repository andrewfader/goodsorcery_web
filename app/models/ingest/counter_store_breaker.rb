# A per-process circuit breaker for the counter buffer's store
# (docs/ARCHITECTURE.md §2.5.2). After a store failure, ingest skips the
# store for WINDOW and writes counters straight to Postgres, so a store that
# is down doesn't make every event wait for its connect timeout. The first
# event after the window tries the store again.
#
#   breaker.open?    # => true while the store is skipped
#   breaker.trip     # => true when this failure opened the breaker (log it once)
class Ingest::CounterStoreBreaker
  WINDOW = 5.seconds

  def initialize
    @mutex = Mutex.new
    @open_until = nil
  end

  def open? = @mutex.synchronize { open_now? }

  def trip
    @mutex.synchronize do
      was_open = open_now?
      @open_until = WINDOW.from_now
      !was_open
    end
  end

  private
    def open_now? = @open_until&.future? || false
end
