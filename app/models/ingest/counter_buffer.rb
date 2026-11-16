# Buffers the counters of ingested events in Valkey/Redis and adds them to
# Postgres in batches, so the hot rows (an issue's counters, its hourly row,
# its stored tag values and the project's hourly row) leave the per-event
# transaction (docs/ARCHITECTURE.md §2.5.2). Sentry's Redis buffers work the
# same way.
#
# - add_event: after the processor's transaction commits, one Lua script adds
#   the event to a pending hash (HINCRBY, plus a maximum for last_seen_at),
#   unless the event's guard key says it was added already. If the store
#   fails, the counts go straight to Postgres instead, and the store is
#   skipped for a few seconds (Ingest::CounterStoreBreaker).
# - flush (FlushIngestCountersJob, every 10 seconds): single-flight
#   (CounterFlush.exclusively); a run that finds another one going exits at
#   once. The pending hash is renamed to a batch key named after its claim
#   time and added to an index set, atomically. The batch is applied in
#   chunks of at most CHUNK_ROWS rows, one short transaction per chunk, each
#   recorded in the CounterFlush ledger, so a chunk is applied exactly once.
#   Then the batch key is deleted. A batch older than RECOVERY_GRACE that is
#   still listed was abandoned by a crashed or failed flush, and the next run
#   applies it (the ledger skips the chunks that already committed).
#
# The client never re-sends a command (reconnect_attempts: 0): a command
# whose reply was lost may have run, and re-sending ADD or CLAIM would count
# an event twice or overwrite a claimed batch. Only idempotent reads and
# deletes are retried, by hand.
#
# Keys and fields hold ids, hours, environment names, tag keys and tag value
# digests only (Ingest::CounterFields), never a tag value or anything else
# captured. Never use the LRU cache instance (REDIS_CACHE_URL): an evicted
# key would lose counts.
class Ingest::CounterBuffer
  NAMESPACE = "goodsorcery:counters"
  # A safety net only: every flush clears what it applied. Refreshed on every
  # write, so pending counts expire only after this long with no event and
  # no flush, and a left-behind batch after this long without a flush.
  KEY_TTL = 7.days
  # How long an event's guard key (seen:<occurrence_id>) lives: far longer
  # than a delayed script, or the fallback right after a lost reply, takes.
  SEEN_TTL = 2.minutes
  # Rows (tag values, issue hours, issues and project hours together) per
  # flush transaction. Big enough that a flush of a busy instance takes a
  # handful of transactions, small enough that each holds its row locks for
  # a few milliseconds and a processor waiting on one of them is barely
  # delayed.
  CHUNK_ROWS = 1_000
  # Fields per HSCAN reply when a flush reads a batch, so no single reply of
  # a big batch can run past the read timeout.
  SCAN_COUNT = 1_000
  # How often FlushIngestCountersJob runs (config/schedule.yml). A flush
  # slower than SLOW is logged at info; one slower than INTERVAL at warn.
  INTERVAL = 10.seconds
  SLOW = 1.second
  # Each kind of warning is logged at most this often per process (at info
  # otherwise, or not at all).
  WARNING_EVERY = 1.minute
  # Runs in a row that found the flush lock taken before that is a warning:
  # a minute of runs, far longer than a healthy flush.
  BUSY_RUNS_WARNING = 6
  # A batch claimed longer ago than this, and still listed, was abandoned.
  # Twelve intervals: far longer than a healthy flush takes even on a busy
  # instance (each chunk commits in milliseconds), so a slow but live run's
  # batch is never taken over, yet a crashed run's counts show within a few
  # minutes. The single-flight lock already keeps two runs apart; the grace
  # covers a run that lost its database connection, and so its lock, while
  # still working.
  RECOVERY_GRACE = 2.minutes
  # Filled lazily, one connection per thread that needs one; at least the
  # Sidekiq concurrency.
  POOL_SIZE = 16
  CLIENT_OPTIONS = { connect_timeout: 0.5, read_timeout: 1, write_timeout: 1, reconnect_attempts: 0 }.freeze
  STORE_ERRORS = [ Redis::BaseError, ConnectionPool::TimeoutError ].freeze
  # Failures after which the command can't have reached the store.
  NOT_SENT_ERRORS = [ Redis::CannotConnectError, ConnectionPool::TimeoutError ].freeze

  # KEYS: pending hash, the event's guard key. ARGV: key TTL, guard TTL, the
  # number of maximum pairs, the (field, value) maximum pairs, then (field,
  # increment) pairs. Returns 0, changing nothing, when the guard exists: the
  # event was added already.
  ADD_SCRIPT = <<~LUA.freeze
    if not redis.call('SET', KEYS[2], '1', 'NX', 'EX', ARGV[2]) then return 0 end
    local key = KEYS[1]
    local last = 3 + tonumber(ARGV[3]) * 2
    for i = 4, last, 2 do
      local current = tonumber(redis.call('HGET', key, ARGV[i]))
      if not current or tonumber(ARGV[i + 1]) > current then redis.call('HSET', key, ARGV[i], ARGV[i + 1]) end
    end
    for i = last + 1, #ARGV, 2 do redis.call('HINCRBY', key, ARGV[i], ARGV[i + 1]) end
    redis.call('EXPIRE', key, ARGV[1])
    return 1
  LUA

  # KEYS: pending hash, batch key, batch index set. ARGV: batch id, TTL.
  # Idempotent: if the batch key exists, this claim already ran, and
  # renaming again would overwrite the batch with newer pending counts.
  CLAIM_SCRIPT = <<~LUA.freeze
    if redis.call('EXISTS', KEYS[2]) == 1 then return 1 end
    if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
    redis.call('RENAME', KEYS[1], KEYS[2])
    redis.call('SADD', KEYS[3], ARGV[1])
    redis.call('EXPIRE', KEYS[3], ARGV[2])
    return 1
  LUA

  SCRIPT_SHAS = [ ADD_SCRIPT, CLAIM_SCRIPT ].to_h { |script| [ script, Digest::SHA1.hexdigest(script) ] }.freeze
  MUTEX = Mutex.new

  class << self
    # What ingest counts with: the buffer when a store is configured and
    # GOODSORCERY_COUNTER_BUFFER isn't off, otherwise Ingest::DirectCounters.
    def current
      buffer = configured if Rails.configuration.x.counter_buffer_enabled
      buffer || Ingest::DirectCounters.new
    end

    # The buffer of the configured store, or nil without one. The flush uses
    # it even with buffering switched off, so counts already buffered still
    # reach Postgres.
    def configured
      url = Rails.configuration.x.counter_buffer_url
      new(connect(url)) if url
    end

    # A connection pool per URL, shared by every buffer in the process.
    def connect(url, **options)
      MUTEX.synchronize do
        (@pools ||= {})[[ url, options ]] ||= ConnectionPool.new(size: POOL_SIZE, timeout: 1) do
          Redis.new(url:, **CLIENT_OPTIONS, **options)
        end
      end
    end

    # One breaker per pool, shared by every buffer in the process.
    def breaker_for(pool)
      MUTEX.synchronize { (@breakers ||= ObjectSpace::WeakKeyMap.new)[pool] ||= Ingest::CounterStoreBreaker.new }
    end

    # At most one warning of each kind per WARNING_EVERY per process.
    def warning_due?(kind)
      MUTEX.synchronize do
        @warned_at ||= {}
        next false if @warned_at[kind]&.after?(WARNING_EVERY.ago)

        @warned_at[kind] = Time.current
      end
    end

    # Counts the runs in a row that found the flush lock taken; returns how
    # many (0 once a run gets the lock).
    def count_busy_run(busy)
      MUTEX.synchronize { @busy_runs = busy ? (@busy_runs || 0) + 1 : 0 }
    end
  end

  def initialize(pool, namespace: NAMESPACE, chunk_rows: CHUNK_ROWS, breaker: self.class.breaker_for(pool))
    @pool, @namespace, @chunk_rows, @breaker = pool, namespace, chunk_rows, breaker
  end

  # Tag increments go to the buffer too (Ingest::Rollups).
  def buffered? = true

  # Adds one event once the surrounding transaction commits: a rolled-back
  # event is never counted, and the occurrence id's guard key keeps a
  # re-sent or fallen-back add from counting it twice. Never raises: the
  # processor's announcements and alerts run after this.
  def add_event(occurrence_id:, **counts)
    totals = Ingest::CounterTotals.for_event(**counts)
    ActiveRecord.after_all_transactions_commit { push_safely(totals, occurrence_id) }
  end

  # Applies everything buffered so far. Returns the number of chunks
  # applied, or nil when another flush is running (its pending counts then
  # roll into the next run).
  def flush
    applied = CounterFlush.exclusively { timed { apply_batches } }
    warn_if_lock_stuck(applied.nil?)
    applied
  end

  # Fields of the pending hash, for tests and debugging.
  def pending = store { |redis| redis.hgetall(pending_key) }

  private
    def store(&) = @pool.with(&)

    # For idempotent commands only: one more try after a connection error.
    def store_with_retry(&)
      attempts = 0
      begin
        store(&)
      rescue Redis::BaseConnectionError
        retry if (attempts += 1) < 2
        raise
      end
    end

    def push_safely(totals, occurrence_id)
      push(totals, occurrence_id)
    rescue StandardError => error
      Rails.logger.error { "Counter buffer lost the counts of one event (#{error.class.name})" }
    end

    def push(totals, occurrence_id)
      return write_directly(totals) if @breaker.open?

      keys = [ pending_key, seen_key(occurrence_id) ]
      store { |redis| run_script(redis, ADD_SCRIPT, keys:, argv: add_arguments(totals)) }
    rescue *STORE_ERRORS => error
      store_failed(error)
      write_directly(totals) if NOT_SENT_ERRORS.any? { error.is_a?(it) } || take_guard(occurrence_id)
    end

    def add_arguments(totals)
      maxima = Ingest::CounterFields.maxima(totals)
      [ KEY_TTL.to_i, SEEN_TTL.to_i, maxima.size, *maxima.flatten, *Ingest::CounterFields.increments(totals).flatten ]
    end

    # The script may have run before its reply was lost. Setting the guard
    # here decides it: if it was free, the script never ran (and never will
    # count the event, should it still arrive), so Postgres counts it.
    def take_guard(occurrence_id)
      store { |redis| redis.set(seen_key(occurrence_id), "1", nx: true, ex: SEEN_TTL.to_i) }
    rescue *STORE_ERRORS
      true # Can't tell; the one window left (docs/ARCHITECTURE.md §2.5.2).
    end

    def store_failed(error)
      return unless @breaker.trip

      Rails.logger.warn do
        "Counter buffer unavailable (#{error.class.name}); counts written to Postgres for #{Ingest::CounterStoreBreaker::WINDOW.to_i} s"
      end
    end

    def write_directly(totals) = ApplicationRecord.transaction { totals.apply }

    # Abandoned batches first, then the pending hash, claimed now. One
    # batch's failure doesn't stop the others; it is retried as abandoned.
    def apply_batches
      batch_ids = abandoned_batch_ids
      batch_ids << claim_pending
      batch_ids.compact.flat_map { |batch_id| apply_batch_safely(batch_id) }
    rescue *STORE_ERRORS => error
      Rails.logger.warn { "Counter flush skipped: store unavailable (#{error.class.name})" }
      []
    end

    def abandoned_batch_ids
      store_with_retry { |redis| redis.smembers(index_key) }.select { |batch_id| abandoned?(batch_id) }.sort.tap do |batch_ids|
        warn_abandoned(batch_ids) if batch_ids.any?
      end
    end

    # The id of the batch claimed now, or nil when nothing is pending or the
    # claim failed (if it ran after all, its batch is recovered later).
    def claim_pending
      batch_id = "#{(Time.current.to_r * 1000).to_i}:#{SecureRandom.uuid}"
      keys = [ pending_key, batch_key(batch_id), index_key ]
      claimed = store { |redis| run_script(redis, CLAIM_SCRIPT, keys:, argv: [ batch_id, KEY_TTL.to_i ]) }
      batch_id if claimed == 1
    rescue *STORE_ERRORS => error
      Rails.logger.warn { "Counter flush couldn't claim the pending counts (#{error.class.name})" }
      nil
    end

    # Batch ids start with their claim time in epoch milliseconds.
    def claimed_at(batch_id) = Time.zone.at(Rational(batch_id.to_i, 1000))

    def abandoned?(batch_id) = claimed_at(batch_id) < RECOVERY_GRACE.ago

    def apply_batch_safely(batch_id)
      apply_batch(batch_id)
    rescue StandardError => error
      age = (Time.current - claimed_at(batch_id)).round
      Rails.logger.error { "Counter flush failed on a batch claimed #{age} s ago (#{error.class.name}); it is retried later" }
      []
    end

    # The chunks this run applied.
    def apply_batch(batch_id)
      applied = batch_totals(batch_id).chunks(@chunk_rows).each_with_index.filter_map do |chunk, index|
        chunk if CounterFlush.apply_once(chunk_id(batch_id, index)) { chunk.apply }
      end
      forget(batch_id)
      announce(applied)
      applied
    end

    def batch_totals(batch_id)
      Ingest::CounterFields.decode(store_with_retry { |redis| redis.hscan_each(batch_key(batch_id), count: SCAN_COUNT).to_a })
    end

    # Stable across retries: a batch key never changes once claimed, and
    # CounterTotals#chunks always splits the same totals the same way (as
    # long as CHUNK_ROWS stays the same).
    def chunk_id(batch_id, index) = Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, "#{batch_id}/#{index}")

    def timed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      chunks = yield
      log_flush(chunks, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      chunks.size
    end

    # Slow flushes only, with counts and the duration.
    def log_flush(chunks, seconds)
      return if seconds <= SLOW

      message = "Counter flush applied #{chunks.sum(&:row_count)} rows in #{chunks.size} chunks in #{(seconds * 1000).round} ms"
      return Rails.logger.info(message) unless seconds > INTERVAL && self.class.warning_due?(:slow)

      Rails.logger.warn("#{message}, longer than the #{INTERVAL.to_i} s interval: counts lag behind")
    end

    def warn_if_lock_stuck(busy)
      runs = self.class.count_busy_run(busy)
      return unless runs >= BUSY_RUNS_WARNING && self.class.warning_due?(:busy)

      Rails.logger.warn("Counter flush lock taken for #{runs} runs in a row: a flush is stuck or slow, counts lag behind")
    end

    def warn_abandoned(batch_ids)
      return unless self.class.warning_due?(:abandoned)

      age = (Time.current - claimed_at(batch_ids.first)).round
      Rails.logger.warn("Counter flush recovering #{batch_ids.size} abandoned batches, the oldest claimed #{age} s ago")
    end

    def forget(batch_id)
      store_with_retry do |redis|
        redis.multi do |transaction|
          transaction.del(batch_key(batch_id))
          transaction.srem(index_key, batch_id)
        end
      end
    end

    # Open pages learn about the new counts through the usual debounced
    # pointer broadcasts (LiveUpdateGate): at most one per issue and project
    # per window, shared with the processors' own.
    def announce(chunks)
      return if chunks.empty?

      Issue.where(id: chunks.flat_map(&:issue_ids).uniq).select(:id, :project_id).each(&:broadcast_changes_later)
      Project.includes(:account).where(id: chunks.flat_map(&:project_ids).uniq).each(&:broadcast_changes_later)
    end

    # EVALSHA, and on a store that hasn't seen the script yet (a restart),
    # EVAL, which also caches it. Both run one of the constant Lua scripts
    # above in Valkey; no Ruby is evaluated. A NOSCRIPT reply means the
    # script didn't run, so sending EVAL is safe.
    def run_script(redis, script, keys:, argv:)
      redis.call("EVALSHA", SCRIPT_SHAS.fetch(script), keys.size, *keys, *argv)
    rescue Redis::CommandError => error
      raise unless error.message.start_with?("NOSCRIPT")

      redis.call("EVAL", script, keys.size, *keys, *argv)
    end

    def pending_key = "#{@namespace}:pending"

    def seen_key(occurrence_id) = "#{@namespace}:seen:#{occurrence_id}"

    def batch_key(batch_id) = "#{@namespace}:batch:#{batch_id}"

    def index_key = "#{@namespace}:batches"
end
