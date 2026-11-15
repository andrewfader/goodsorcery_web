require "test_helper"
require "socket"

class Ingest::QueueLatencyTest < ActiveSupport::TestCase
  def sidekiq_job
    Class.new(ApplicationJob) do
      self.queue_adapter = :sidekiq
      queue_as :ingest
    end
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # Connections the kernel completed on `server`, closed or not: they wait
  # in the accept queue, so counting needs no accepting thread.
  def accepted_connections(server)
    count = 0
    while (socket = server.accept_nonblock(exception: false)) != :wait_readable
      socket.close
      count += 1
    end
    count
  end

  test "is 0 outside the Sidekiq adapter, without touching Redis" do
    latency = Ingest::QueueLatency.new(redis_options: { url: "redis://127.0.0.1:1/0" })
    assert_equal 0.0, latency.seconds
  end

  test "with Sidekiq, reads the queue through its own pool, failing fast when Redis is unreachable" do
    latency = Ingest::QueueLatency.new(job: sidekiq_job, redis_options: { url: "redis://127.0.0.1:1/0" })

    seconds = elapsed { assert_raises(RedisClient::CannotConnectError) { latency.seconds } }
    assert_operator seconds, :<, 2
  end

  # A Redis that accepts the connection and never answers: the read gives up
  # after one READ_TIMEOUT, on one connection. Sidekiq's 3 s default timeout
  # or its reconnect attempt (a second connection, a second wait) fail this.
  test "a Redis that never answers costs one read timeout, with no reconnect" do
    server = TCPServer.new("127.0.0.1", 0)
    latency = Ingest::QueueLatency.new(job: sidekiq_job, redis_options: { url: "redis://127.0.0.1:#{server.addr[1]}/0" })

    seconds = elapsed { assert_raises(RedisClient::ConnectionError) { latency.seconds } }
    assert_in_delta Ingest::QueueLatency::READ_TIMEOUT, seconds, 0.5
    assert_equal 1, accepted_connections(server)
  ensure
    server&.close
  end
end
