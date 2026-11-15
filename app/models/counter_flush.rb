# One chunk of buffered ingest counters that a flush has added to Postgres
# (docs/ARCHITECTURE.md §2.5.2), and the single-flight lock of the flush.
#
# The row is written in the same transaction as the chunk's counts, so a
# chunk is applied exactly once: a flush that crashed after COMMIT but before
# deleting its Valkey key, or a recovered batch that turns out to have been
# applied after all, finds the row and skips the chunk.
#
#   CounterFlush.exclusively { … }                       # => nil while another flush runs
#   CounterFlush.apply_once(chunk_id) { totals.apply }  # => true, or false if already applied
class CounterFlush < ApplicationRecord
  # Advisory lock namespace (other namespaces: AlertDelivery, SlackDelivery, Signup).
  FLUSH_LOCK = 4_714
  # Longer than a buffered key can live (Ingest::CounterBuffer::KEY_TTL), so
  # a leftover batch is always recognised. Pruned by goodsorcery:prune.
  KEPT_FOR = Ingest::CounterBuffer::KEY_TTL + 1.day
  # A chunk's statements finish in milliseconds; one stuck behind a lock or
  # a slow disk is cancelled after this, rolled back, and retried later, so
  # it can't hold its row locks, or the flush lock, indefinitely.
  STATEMENT_TIMEOUT = 5.seconds

  class << self
    # Runs the block unless another flush holds the lock, and returns its
    # value (nil when the lock was taken). A session-level advisory lock on
    # this thread's connection: Postgres drops it if the process or the
    # connection dies, so a crashed flush can't leave it behind and nothing
    # has to renew it. It needs a session-pooled connection (never PgBouncer
    # transaction pooling). Uncached: jobs run with the query cache on.
    def exclusively
      return unless uncached { connection.select_value("SELECT pg_try_advisory_lock(#{FLUSH_LOCK}, 1)") }

      begin
        yield
      ensure
        unlock
      end
    end

    # Runs the block and records chunk_id in one transaction, unless chunk_id
    # was recorded before. Returns whether the block ran.
    def apply_once(chunk_id)
      transaction do
        connection.execute("SET LOCAL statement_timeout = #{STATEMENT_TIMEOUT.in_milliseconds.to_i}")
        next false if insert({ id: chunk_id }, returning: :id).rows.empty?

        yield
        true
      end
    end

    private
      # False when this session no longer held the lock: its connection was
      # replaced (or pooled per transaction) while the flush ran, so another
      # run may have overlapped it.
      def unlock
        return if uncached { connection.select_value("SELECT pg_advisory_unlock(#{FLUSH_LOCK}, 1)") }

        Rails.logger.warn("Counter flush lock was no longer held when the flush ended: check the database connection pooling")
      end
  end
end
