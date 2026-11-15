require "sidekiq/api"

# How long, in seconds, the oldest job waiting in Sidekiq's ingest queue has
# waited (Sidekiq::Queue#latency: one LINDEX, no Postgres). The retry and dead
# sets don't count. Outside the Sidekiq adapter (development and test run
# jobs in process) nothing waits in Redis, so it is 0.
#
# Reads go through a one-connection pool of their own, never the pool
# enqueueing uses, with no reconnect attempt (Sidekiq's default is one) and
# a budget per step. redis-client gives DNS, the TCP connect and each TLS
# handshake wait CONNECT_TIMEOUT each, and every reply READ_TIMEOUT. A stall
# at one step costs that step's budget: about 1 s on an open connection,
# 1-1.5 s while connecting. Only a Redis slow at every step without failing
# any could add them up, to about 3.5 s. Ingest::Backlog reads it from one
# request thread per process at most every 5 s, so that is the whole cost.
#
# READ_TIMEOUT is 1 s, redis-client's default, rather than shorter. While a
# thread waits for the reply it doesn't hold the GVL, so a busy Puma process
# delays its wake-up but can't turn a reply that came in time into a
# timeout. What can be slow is Redis itself, under the enqueue load of the
# very incident shedding is for; a shorter read would then fail repeatedly,
# the sample would pass Ingest::Backlog::MAX_AGE and ingest would admit
# exactly when it should shed. The same request goes on to enqueue through
# Sidekiq's own pool with a 3 s timeout, so 1 s adds no new kind of wait.
#
# It connects where Sidekiq connects: config.x.ingest.queue_redis_options,
# built once at boot (config/application.rb). Any future Sidekiq Redis
# initializer must feed those options too.
class Ingest::QueueLatency
  CONNECT_TIMEOUT = 0.5
  READ_TIMEOUT = 1
  POOL_TIMEOUT = 0.5

  def initialize(job: ProcessInboundEventJob, redis_options: Rails.configuration.x.ingest.queue_redis_options)
    @job = job
    @redis_options = redis_options
  end

  def seconds
    return 0.0 unless @job.queue_adapter_name == "sidekiq"

    Sidekiq::Client.via(pool) { Sidekiq::Queue.new(@job.queue_name).latency }
  end

  private
    # One connection: Ingest::Backlog reads from one thread at a time, so
    # POOL_TIMEOUT is never waited for in practice.
    def pool
      @pool ||= Sidekiq::RedisConnection.create(
        **@redis_options, size: 1, pool_timeout: POOL_TIMEOUT, reconnect_attempts: 0,
        connect_timeout: CONNECT_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: CONNECT_TIMEOUT
      )
    end
end
