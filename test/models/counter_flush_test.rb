require "test_helper"

class CounterFlushTest < ActiveSupport::TestCase
  test "apply_once runs the block once per chunk id" do
    chunk_id = SecureRandom.uuid
    runs = 0

    assert CounterFlush.apply_once(chunk_id) { runs += 1 }
    assert_not CounterFlush.apply_once(chunk_id) { runs += 1 }
    assert_equal 1, runs
  end

  test "a chunk whose block raises is not recorded, so it is applied on the next try" do
    chunk_id = SecureRandom.uuid
    assert_raises(RuntimeError) { CounterFlush.apply_once(chunk_id) { raise "boom" } }
    assert_not CounterFlush.exists?(chunk_id)
    assert CounterFlush.apply_once(chunk_id) { }
  end

  test "a chunk's statements run under the flush's statement timeout" do
    CounterFlush.apply_once(SecureRandom.uuid) do
      assert_equal "5s", CounterFlush.connection.select_value("SHOW statement_timeout")
    end
  end

  test "exclusively runs the block unless another session holds the flush lock" do
    assert_equal :ran, CounterFlush.exclusively { :ran }

    other = new_session
    other.execute("SELECT pg_advisory_lock(#{CounterFlush::FLUSH_LOCK}, 1)")
    assert_nil CounterFlush.exclusively { :ran }
    other.execute("SELECT pg_advisory_unlock(#{CounterFlush::FLUSH_LOCK}, 1)")
    other.disconnect!

    assert_equal :ran, CounterFlush.exclusively { :ran }
  end

  test "a closed session releases the lock" do
    other = new_session
    other.execute("SELECT pg_advisory_lock(#{CounterFlush::FLUSH_LOCK}, 1)")
    other.disconnect!

    # Postgres releases a closed session's locks once its backend exits,
    # which happens shortly after the disconnect, not during it.
    assert wait_until_lock_free, "the lock was still held 5 s after the session closed"
    assert_equal :ran, CounterFlush.exclusively { :ran }
  end

  test "exclusively releases the lock when the block raises" do
    assert_raises(RuntimeError) { CounterFlush.exclusively { raise "boom" } }
    assert_equal :ran, CounterFlush.exclusively { :ran }
  end

  test "a flush that no longer holds the lock when it ends says so" do
    output = StringIO.new
    previous, Rails.logger = Rails.logger, ActiveSupport::Logger.new(output)
    CounterFlush.exclusively { CounterFlush.connection.select_value("SELECT pg_advisory_unlock(#{CounterFlush::FLUSH_LOCK}, 1)") }

    assert_match(/Counter flush lock was no longer held when the flush ended/, output.string)
  ensure
    Rails.logger = previous
  end

  private
    def new_session
      ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    def wait_until_lock_free(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until lock_free?
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
      true
    end

    def lock_free?
      sql = "SELECT NOT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND classid = #{CounterFlush::FLUSH_LOCK} " \
            "AND objid = 1 AND objsubid = 2 AND granted " \
            "AND database = (SELECT oid FROM pg_database WHERE datname = current_database()))"
      CounterFlush.connection.select_value(sql)
    end
end
