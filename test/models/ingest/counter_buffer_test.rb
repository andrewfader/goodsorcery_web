require "test_helper"
require_relative "ingest_test_support"
require_relative "../../test_helpers/counter_buffer_test_helper"

# The Valkey counter buffer against a real store (skipped without REDIS_URL;
# CI runs a Valkey service). The fallback and breaker tests need no store.
class Ingest::CounterBufferTest < ActiveSupport::TestCase
  include IngestTestSupport
  include CounterBufferTestHelper
  include ActiveJob::TestHelper

  setup do
    @project = projects(:storefront)
    @issue = issues(:nomethod)
    @other = issues(:regressed)
    @hour = TimeSeries.align(Time.current, 1.hour)
    @chrome = [ @issue.id, "browser", IssueTagCount.value_digest("browser", "Chrome") ]
    @occurrence_ids = (1..).each
    Ingest::CounterBuffer.instance_variable_set(:@warned_at, nil) # each test starts with no recent warning
  end

  teardown { clear_counter_store }

  test "events are buffered after commit, not written to Postgres" do
    buffer = counter_buffer
    assert_no_difference [ -> { @issue.reload.events_count }, -> { ProjectHourlyCount.sum(:count) }, -> { IssueTagCount.sum(:count) } ] do
      ApplicationRecord.transaction { add(buffer, @issue, at: @hour + 1.minute, new_user: true, tag_rows: [ @chrome ]) }
    end

    assert_equal({ "t:#{@chrome.join(":")}" => "1", "ih:#{@issue.id}:#{@hour.to_i}" => "1", "e:#{@issue.id}" => "1",
                   "u:#{@issue.id}" => "1", "l:#{@issue.id}" => microseconds(@hour + 1.minute),
                   "ph:#{@project.id}:#{@hour.to_i}:production" => "1" }, buffer.pending)
  end

  test "an event whose transaction rolls back is never buffered" do
    buffer = counter_buffer
    ApplicationRecord.transaction do
      add(buffer, @issue, at: @hour)
      raise ActiveRecord::Rollback
    end
    assert_empty buffer.pending
  end

  test "an event added twice, as a re-sent add would, counts once" do
    buffer = counter_buffer
    2.times { add(buffer, @issue, at: @hour, occurrence_id: 41) }
    add(buffer, @issue, at: @hour, occurrence_id: 42)

    assert_equal "2", buffer.pending["e:#{@issue.id}"]
    assert_equal 2, counter_seen_keys.size
  end

  test "flush sums many events across issues, counts stored tag values and keeps last_seen_at as a maximum" do
    buffer = counter_buffer
    @issue.update_columns(last_seen_at: @hour)
    latest = @hour + 40.minutes
    [ 10, 40, 20 ].each { |minutes| add(buffer, @issue, at: @hour + minutes.minutes, new_user: minutes == 20, tag_rows: [ @chrome ]) }
    add(buffer, @other, at: @hour - 2.hours, environment: "staging")

    assert_difference -> { @issue.reload.events_count } => 3, -> { @issue.reload.users_count } => 1,
                      -> { @other.reload.events_count } => 1,
                      -> { IssueHourlyCount.where(issue: @issue, hour: @hour).sum(:count) } => 3,
                      -> { ProjectHourlyCount.where(project: @project, environment: "production", hour: @hour).sum(:count) } => 3,
                      -> { ProjectHourlyCount.where(project: @project, environment: "staging").sum(:count) } => 1,
                      -> { issue_tag_counts(:nomethod_browser_chrome).reload.count } => 3 do
      assert_equal 1, buffer.flush
    end
    assert_equal latest, @issue.reload.last_seen_at
    assert_empty counter_store_dump, "the flush clears every key it applied"
  end

  test "a backdated event counts toward this month's quota, buffered or written directly" do
    json = minimal_json(occurred_at: "2026-10-31T23:00:00Z")
    travel_to Time.utc(2026, 11, 13, 12) do
      dead = Ingest::CounterBuffer.new(dead_pool, namespace: "test:dead", breaker: Ingest::CounterStoreBreaker.new)
      assert_difference(-> { accounts(:acme).events_this_month }, 1, "store down") { process_with(dead, json) }

      buffer = counter_buffer
      assert_difference(-> { accounts(:acme).events_this_month }, 1, "buffered") do
        process_with(buffer, minimal_json(occurred_at: "2026-10-31T23:00:00Z"))
        buffer.flush
      end
    end
  end

  test "a flush larger than one chunk applies every chunk once" do
    buffer = counter_buffer(chunk_rows: 2)
    6.times { |i| add(buffer, @issue, at: @hour - i.hours) }
    add(buffer, @other, at: @hour)

    assert_difference -> { @issue.reload.events_count } => 6, -> { IssueHourlyCount.where(issue: @issue).sum(:count) } => 6,
                      -> { ProjectHourlyCount.where(project: @project).sum(:count) } => 7, -> { CounterFlush.count } => 8 do
      assert_equal 8, buffer.flush # 7 issue hours + 2 issues + 6 project hours = 15 rows
    end
  end

  test "a crash after chunk k of n re-applies only the chunks that didn't commit" do
    buffer = counter_buffer(chunk_rows: 2)
    6.times { |i| add(buffer, @issue, at: @hour - i.hours) }
    add(buffer, @other, at: @hour)

    issue_hours = -> { IssueHourlyCount.where(issue: @issue).sum(:count) }
    before = [ @issue.reload.events_count, issue_hours.call, ProjectHourlyCount.where(project: @project).sum(:count) ]

    assert_difference(-> { CounterFlush.count }, 3, "chunks 1-3 committed") do
      log = capture_log { crash_after_chunks(3) { assert_equal 0, buffer.flush } }
      assert_match(/\ACounter flush failed on a batch claimed 0 s ago \(RuntimeError\); it is retried later\n\z/, log)
    end
    travel Ingest::CounterBuffer::RECOVERY_GRACE + 1.second
    assert_equal 5, counter_buffer(chunk_rows: 2).flush

    after = [ @issue.reload.events_count, issue_hours.call, ProjectHourlyCount.where(project: @project).sum(:count) ]
    assert_equal [ 6, 6, 7 ], after.zip(before).map { |now, was| now - was }
    assert_empty counter_store_dump
  end

  test "a crash between COMMIT and deleting the key doesn't count twice" do
    buffer = counter_buffer
    add(buffer, @issue, at: @hour)
    buffer.define_singleton_method(:forget) { |_batch_id| raise "simulated crash" }
    assert_difference(-> { @issue.reload.events_count }, 1) { capture_log { buffer.flush } }

    travel Ingest::CounterBuffer::RECOVERY_GRACE + 1.second
    assert_no_difference(-> { @issue.reload.events_count }) { assert_equal 0, counter_buffer.flush }
    assert_empty counter_store_dump, "the recovered batch is deleted"
  end

  test "a batch that fails doesn't stop the others: the freshly claimed batch still applies" do
    stuck = counter_buffer
    add(stuck, @issue, at: @hour)
    stuck.send(:claim_pending)
    travel Ingest::CounterBuffer::RECOVERY_GRACE + 1.second

    buffer = counter_buffer
    add(buffer, @other, at: @hour)
    calls = 0
    buffer.define_singleton_method(:batch_totals) do |batch_id|
      raise ActiveRecord::QueryCanceled, "simulated statement timeout" if (calls += 1) == 1

      super(batch_id)
    end

    log = capture_log do
      assert_difference -> { @other.reload.events_count } => 1, -> { @issue.reload.events_count } => 0 do
        assert_equal 1, buffer.flush
      end
    end
    assert_match(/failed on a batch claimed 12[01] s ago \(ActiveRecord::QueryCanceled\)/, log)
    assert_no_match(/simulated/, log, "error messages are never logged")
    assert_difference(-> { @issue.reload.events_count }, 1, "retried by the next run") { assert_equal 1, buffer.flush }
  end

  test "a second flush while one holds the lock does nothing" do
    buffer = counter_buffer
    add(buffer, @issue, at: @hour)

    holding_flush_lock do
      assert_no_difference(-> { @issue.reload.events_count }) { assert_nil buffer.flush }
    end
    assert_not_empty buffer.pending, "pending counts roll into the next run"
    assert_difference(-> { @issue.reload.events_count }, 1) { buffer.flush }
  end

  test "a lock taken for several runs in a row is a warning, at most once a minute" do
    buffer = counter_buffer
    Ingest::CounterBuffer.count_busy_run(false)
    holding_flush_lock do
      quiet = capture_log { (Ingest::CounterBuffer::BUSY_RUNS_WARNING - 1).times { buffer.flush } }
      assert_empty quiet
      assert_match(/\AW Counter flush lock taken for 6 runs in a row/, capture_log(format: true) { buffer.flush })
      assert_empty capture_log { buffer.flush }, "rate-limited"
    end
    assert_equal 0, Ingest::CounterBuffer.count_busy_run(false)
  end

  test "a slow flush's batch isn't taken over; once abandoned past the grace it is recovered exactly once, with a warning" do
    slow = counter_buffer
    add(slow, @issue, at: @hour)
    slow.send(:claim_pending) # claimed by a run still working on it

    assert_no_difference(-> { @issue.reload.events_count }) { assert_equal 0, counter_buffer.flush }
    assert_equal 1, counter_store_dump.size - 1, "the batch key is still there, beside its index"

    travel Ingest::CounterBuffer::RECOVERY_GRACE + 1.second
    assert_difference(-> { @issue.reload.events_count }, 1) do
      log = capture_log(format: true) { assert_equal 1, counter_buffer.flush }
      assert_match(/\AW Counter flush recovering 1 abandoned batches, the oldest claimed \d+ s ago\n\z/, log)
      assert_equal 0, counter_buffer.flush
    end
  end

  test "counts that arrive during a long flush are applied by the next run" do
    buffer = counter_buffer
    add(buffer, @issue, at: @hour)
    during_first_chunk(-> { 2.times { add(buffer, @issue, at: @hour) } }) do
      assert_difference(-> { @issue.reload.events_count }, 1) { buffer.flush }
    end

    assert_difference(-> { @issue.reload.events_count }, 2) { buffer.flush }
  end

  test "a flush with nothing pending touches no table" do
    buffer = counter_buffer
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { assert_equal 0, buffer.flush }
    assert_equal 2, statements.size, "only the lock and unlock: #{statements.join("\n")}"
  end

  test "a flush announces the touched issues and projects through the debounced broadcasts" do
    buffer = counter_buffer
    add(buffer, @issue, at: @hour)
    calls = recording_broadcasts { buffer.flush }

    assert_includes calls, [ "Issue", @issue.id, {} ]
    assert_includes calls, [ "Project", @project.id, {} ]
  end

  test "a processed event leaves tag value digests in the store, never tag values or other captured data" do
    buffer = counter_buffer
    process_event(event_json)
    stored = nil
    log = capture_log do
      Ingest::Processor.new(inbound_event_for(event_json("full", event_id: SecureRandom.uuid)), counters: buffer).process
      stored = [ counter_store_dump, counter_seen_keys ]
      buffer.flush
    end

    fields = stored.first.values.select { |value| value.is_a?(Hash) }.flat_map(&:keys)
    assert_includes fields.map { it.split(":").first }.uniq.sort, "t"
    fields.each do |field|
      assert_match(/\A(?:[eul]:\d+|ih:\d+:\d+|ph:\d+:\d+:[a-z0-9_-]+|t:\d+:[a-z0-9_.-]+:(?:\h{64}|other))\z/i, field)
    end
    stored.last.each { |key| assert_match(/:seen:\d+\z/, key) }
    serialized = [ stored.to_json, counter_store_dump.to_json, log, enqueued_jobs.map { |job| job["arguments"] }.to_json ].join
    [ "price_cents", "mara", "NoMethodError", "cart_total", "CheckoutsController", "example.com", "Mobile Safari", "FALL25" ].each do |text|
      assert_not_includes serialized, text
    end
  end

  test "the store holds tag value digests while a batch waits, and never the values" do
    buffer = counter_buffer
    issue = process_event(event_json)
    Ingest::Processor.new(inbound_event_for(event_json("full", event_id: SecureRandom.uuid)), counters: buffer).process

    safari = IssueTagCount.value_digest("browser", "Mobile Safari")
    assert_equal "1", buffer.pending["t:#{issue.id}:browser:#{safari}"]
    assert_not_includes buffer.pending.to_json, "Safari"
  end

  test "when the store can't be reached, counts go straight to Postgres" do
    buffer = Ingest::CounterBuffer.new(dead_pool, namespace: "test:dead", breaker: Ingest::CounterStoreBreaker.new)

    assert_difference -> { @issue.reload.events_count } => 1, -> { IssueHourlyCount.where(issue: @issue, hour: @hour).sum(:count) } => 1,
                      -> { issue_tag_counts(:nomethod_browser_chrome).reload.count } => 1 do
      add(buffer, @issue, at: @hour, tag_rows: [ @chrome ])
    end
  end

  test "after a store failure, events skip the store for a few seconds, then try it again" do
    pool = counting_pool(dead_pool)
    buffer = Ingest::CounterBuffer.new(pool, namespace: "test:dead", breaker: Ingest::CounterStoreBreaker.new)

    log = capture_log(format: true) do
      assert_difference(-> { @issue.reload.events_count }, 3) { 3.times { add(buffer, @issue, at: @hour) } }
    end
    assert_equal 1, pool.checkouts, "only the first event tried the store"
    assert_match(/\AW Counter buffer unavailable \(Redis::CannotConnectError\); counts written to Postgres for 5 s\n\z/, log)

    travel Ingest::CounterStoreBreaker::WINDOW + 1.second
    capture_log { add(buffer, @issue, at: @hour) }
    assert_equal 2, pool.checkouts
  end

  test "a reply lost after ADD ran: the fallback finds the guard taken and doesn't count again" do
    buffer = counter_buffer
    after_script(buffer, Ingest::CounterBuffer::ADD_SCRIPT) { raise Redis::TimeoutError, "Waited 1.0 seconds" }

    assert_no_difference -> { @issue.reload.events_count } do
      capture_log { add(buffer, @issue, at: @hour, occurrence_id: 7) }
    end
    assert_equal "1", buffer.pending["e:#{@issue.id}"]
  end

  test "a timeout before ADD ran: the fallback takes the guard and counts, and the late script then adds nothing" do
    buffer = counter_buffer
    buffer.define_singleton_method(:run_script) { |*, **| raise Redis::TimeoutError, "Waited 1.0 seconds" }

    assert_difference(-> { @issue.reload.events_count }, 1) { capture_log { add(buffer, @issue, at: @hour, occurrence_id: 8) } }

    late = counter_buffer
    totals = Ingest::CounterTotals.for_event(project_id: @project.id, environment: "production", occurred_at: @hour,
                                             received_at: @hour, issue_id: @issue.id)
    assert_equal 0, late.send(:store) { |redis| late.send(:run_script, redis, Ingest::CounterBuffer::ADD_SCRIPT,
                                                           keys: [ late.send(:pending_key), late.send(:seen_key, 8) ],
                                                           argv: late.send(:add_arguments, totals)) }
    assert_empty late.pending
  end

  test "a re-sent CLAIM of a batch already claimed keeps the batch and the newer pending counts" do
    buffer = counter_buffer
    add(buffer, @issue, at: @hour)
    batch_id = "#{(Time.current.to_r * 1000).to_i}:#{SecureRandom.uuid}"
    claim = -> { claim_script(buffer, batch_id) }

    assert_equal 1, claim.call
    add(buffer, @issue, at: @hour)
    add(buffer, @issue, at: @hour)
    assert_equal 1, claim.call, "the re-sent claim reports success"

    batch = counter_pool.with { |redis| redis.hgetall("#{counter_namespace}:batch:#{batch_id}") }
    assert_equal "1", batch["e:#{@issue.id}"]
    assert_equal "2", buffer.pending["e:#{@issue.id}"]
  end

  test "a CLAIM whose reply is lost: the run logs it and the batch is recovered after the grace, exactly once" do
    buffer = counter_buffer
    3.times { add(buffer, @issue, at: @hour) }
    after_script(buffer, Ingest::CounterBuffer::CLAIM_SCRIPT) { raise Redis::TimeoutError, "Waited 1.0 seconds" }

    log = capture_log { assert_no_difference(-> { @issue.reload.events_count }) { assert_equal 0, buffer.flush } }
    assert_match(/couldn't claim the pending counts \(Redis::TimeoutError\)/, log)

    travel Ingest::CounterBuffer::RECOVERY_GRACE + 1.second
    assert_difference(-> { @issue.reload.events_count }, 3) { capture_log { assert_equal 1, counter_buffer.flush } }
    assert_no_difference(-> { @issue.reload.events_count }) { assert_equal 0, counter_buffer.flush }
  end

  test "through a proxy that delays the ADD reply past the read timeout, the client never re-sends and the event counts once" do
    proxy = delaying_proxy(delay_command: "EVALSHA", delay: 0.6, count: "EVAL")
    counter_pool.with { |redis| redis.script(:load, Ingest::CounterBuffer::ADD_SCRIPT) }
    buffer = proxied_counter_buffer(proxy)

    assert_no_difference -> { @issue.reload.events_count } do
      log = capture_log { add(buffer, @issue, at: @hour, occurrence_id: 9) }
      assert_match(/Redis::(?:Read)?TimeoutError/, log)
    end
    assert_equal 1, proxy.counted, "one EVALSHA, never re-sent"
    assert_equal "1", counter_buffer.pending["e:#{@issue.id}"]
  ensure
    proxy&.close
  end

  test "through a proxy that delays the CLAIM reply, the claimed batch is never overwritten and is applied once" do
    buffer = counter_buffer
    2.times { add(buffer, @issue, at: @hour) }
    proxy = delaying_proxy(delay_command: "EVALSHA", delay: 0.6, count: "EVAL")
    counter_pool.with { |redis| redis.script(:load, Ingest::CounterBuffer::CLAIM_SCRIPT) }
    proxied = proxied_counter_buffer(proxy)

    capture_log { assert_equal 0, proxied.flush }
    add(buffer, @issue, at: @hour)
    assert_equal 1, proxy.counted, "one claim, never re-sent"

    travel Ingest::CounterBuffer::RECOVERY_GRACE + 1.second
    assert_difference(-> { @issue.reload.events_count }, 3) { capture_log { counter_buffer.flush } }
    assert_empty counter_store_dump
  ensure
    proxy&.close
  end

  test "slow flushes are logged with counts only, past the interval at warn at most once a minute" do
    buffer = Ingest::CounterBuffer.new(dead_pool)
    chunks = Ingest::CounterTotals.for_event(project_id: @project.id, environment: "production", occurred_at: @hour,
                                             received_at: @hour, issue_id: @issue.id).chunks(2)

    assert_empty capture_log { buffer.send(:log_flush, chunks, 0.5) }
    assert_match(/\AI.*applied 3 rows in 2 chunks in 1500 ms\n\z/, capture_log(format: true) { buffer.send(:log_flush, chunks, 1.5) })
    assert_match(/\AW.*applied 3 rows in 2 chunks in 12000 ms, longer than the 10 s interval/,
                 capture_log(format: true) { buffer.send(:log_flush, chunks, 12) })
    assert_match(/\AI.*in 13000 ms/, capture_log(format: true) { buffer.send(:log_flush, chunks, 13) }, "rate-limited")
  end

  test "the client never re-sends a command" do
    assert_equal 0, Ingest::CounterBuffer::CLIENT_OPTIONS[:reconnect_attempts]
    Ingest::CounterBuffer.connect("redis://127.0.0.1:1").with do |redis|
      assert_not redis._client.config.retry_connecting?(0, Redis::TimeoutError.new)
    end
  end

  test "current is the buffer only with a store configured and buffering on" do
    assert_kind_of Ingest::DirectCounters, Ingest::CounterBuffer.current
    assert_nil Ingest::CounterBuffer.configured

    with_counter_config(url: "redis://127.0.0.1:6379/0", enabled: true) do
      assert_kind_of Ingest::CounterBuffer, Ingest::CounterBuffer.current
    end
    with_counter_config(url: "redis://127.0.0.1:6379/0", enabled: false) do
      assert_kind_of Ingest::DirectCounters, Ingest::CounterBuffer.current
      assert_kind_of Ingest::CounterBuffer, Ingest::CounterBuffer.configured, "still flushes what was buffered"
    end
  end

  private
    def add(buffer, issue, at:, new_user: false, environment: "production", tag_rows: [], occurrence_id: @occurrence_ids.next)
      buffer.add_event(project_id: issue.project_id, environment:, occurred_at: at, received_at: at, issue_id: issue.id,
                       new_user:, tag_rows:, occurrence_id:)
    end

    def process_with(counters, json)
      Ingest::Processor.new(inbound_event_for(json), counters:).process
    end

    def microseconds(time) = (time.to_r * 1_000_000).to_i.to_s

    def dead_pool = ConnectionPool.new(size: 1) { Redis.new(url: "redis://127.0.0.1:1", connect_timeout: 0.1, reconnect_attempts: 0) }

    # A pool that counts how often it is used.
    def counting_pool(pool)
      pool.tap do |counted|
        counted.instance_variable_set(:@checkouts, 0)
        def counted.checkouts = @checkouts
        def counted.with(...) = (@checkouts += 1) && super(...)
      end
    end

    # The given script runs in the store, then the block runs (raising, as a
    # lost reply would).
    def after_script(buffer, script)
      buffer.define_singleton_method(:run_script) do |redis, run, keys:, argv:|
        result = super(redis, run, keys:, argv:)
        yield if run == script
        result
      end
    end

    def claim_script(buffer, batch_id)
      keys = [ buffer.send(:pending_key), buffer.send(:batch_key, batch_id), buffer.send(:index_key) ]
      buffer.send(:store) { |redis| buffer.send(:run_script, redis, Ingest::CounterBuffer::CLAIM_SCRIPT, keys:, argv: [ batch_id, 60 ]) }
    end

    # CounterFlush.apply_once raises once +count+ chunks have committed.
    def crash_after_chunks(count, &)
      calls = 0
      replacing_apply_once(->(original, chunk_id, &block) {
        raise "simulated crash" if (calls += 1) > count

        original.call(chunk_id, &block)
      }, &)
    end

    # Runs +action+ while the first chunk is being applied.
    def during_first_chunk(action, &)
      calls = 0
      replacing_apply_once(->(original, chunk_id, &block) {
        action.call if (calls += 1) == 1
        original.call(chunk_id, &block)
      }, &)
    end

    def replacing_apply_once(replacement)
      original = CounterFlush.method(:apply_once)
      CounterFlush.define_singleton_method(:apply_once) { |chunk_id, &block| replacement.call(original, chunk_id, &block) }
      yield
    ensure
      CounterFlush.define_singleton_method(:apply_once, original)
    end

    # Holds the flush lock on a connection of its own, as a running flush
    # would. Unlocked explicitly: Postgres releases a closed session's locks
    # asynchronously, so a later test could still find it taken.
    def holding_flush_lock
      connection = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(ActiveRecord::Base.connection_db_config.configuration_hash)
      connection.execute("SELECT pg_advisory_lock(#{CounterFlush::FLUSH_LOCK}, 1)")
      yield
    ensure
      connection&.execute("SELECT pg_advisory_unlock(#{CounterFlush::FLUSH_LOCK}, 1)")
      connection&.disconnect!
    end

    # The log written in the block; format: true prefixes each line with its
    # severity letter.
    def capture_log(format: false)
      output = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(output)
      Rails.logger.formatter = ->(severity, _time, _program, message) { "#{severity[0]} #{message}\n" } if format
      yield
      output.string
    ensure
      Rails.logger = previous
    end

    def with_counter_config(url:, enabled:)
      config = Rails.configuration.x
      previous = [ config.counter_buffer_url, config.counter_buffer_enabled ]
      config.counter_buffer_url, config.counter_buffer_enabled = url, enabled
      yield
    ensure
      config.counter_buffer_url, config.counter_buffer_enabled = previous
    end
end
