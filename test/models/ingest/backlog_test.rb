require "test_helper"

class Ingest::BacklogTest < ActiveSupport::TestCase
  # A latency source that counts its reads; set `failure` to make reads raise.
  class FakeLatency
    attr_accessor :seconds_value, :failure
    attr_reader :reads

    def initialize(seconds_value)
      @seconds_value = seconds_value
      @reads = 0
    end

    def seconds
      @reads += 1
      raise failure if failure

      seconds_value
    end
  end

  setup do
    freeze_time
    @source = FakeLatency.new(0)
    @log = StringIO.new
  end

  def backlog(shed_after: 120, resume_below: 30, source: @source)
    Ingest::Backlog.new(shed_after:, resume_below:, source:, logger: ActiveSupport::Logger.new(@log))
  end

  # Moves past the refresh interval so the next check reads the source again.
  def next_read = travel(Ingest::Backlog::REFRESH_INTERVAL)

  test "admits below the shed threshold and sheds at it" do
    backlog = backlog()
    @source.seconds_value = 119.9
    assert_not backlog.shedding?

    next_read
    @source.seconds_value = 120
    assert backlog.shedding?
  end

  test "hysteresis: keeps shedding until the latency falls below the resume threshold" do
    backlog = backlog()
    @source.seconds_value = 300
    assert backlog.shedding?

    [ 119, 30 ].each do |seconds|
      next_read
      @source.seconds_value = seconds
      assert backlog.shedding?, "still shedding at #{seconds} s"
    end

    next_read
    @source.seconds_value = 29
    assert_not backlog.shedding?

    next_read
    @source.seconds_value = 100
    assert_not backlog.shedding?, "does not start again until the shed threshold"
  end

  test "reads the source at most once per refresh interval" do
    backlog = backlog()
    3.times { backlog.shedding? }
    assert_equal 1, @source.reads

    @source.seconds_value = 500
    travel(Ingest::Backlog::REFRESH_INTERVAL - 1.second)
    assert_not backlog.shedding?, "uses the memo until the interval has passed"
    assert_equal 1, @source.reads

    travel(1.second)
    assert backlog.shedding?
    assert_equal 2, @source.reads
  end

  test "single flight: while one thread reads, the others use the last value without waiting" do
    reading = Queue.new
    release = Queue.new
    source = FakeLatency.new(500)
    source.define_singleton_method(:seconds) do
      reading << true
      release.pop
      super()
    end
    backlog = backlog(source:)

    reader = Thread.new { backlog.shedding? }
    reading.pop
    assert_not backlog.shedding?, "no value yet: admits instead of waiting for the read"
    release << true

    assert reader.value
    assert_equal 1, source.reads
  end

  test "a failed read keeps the last value, logged by error class only" do
    backlog = backlog()
    @source.seconds_value = 300
    assert backlog.shedding?

    next_read
    @source.failure = RedisClient::ReadTimeoutError.new("timed out reading from redis://secret-host:6379")
    assert backlog.shedding?
    assert_equal 300.0, backlog.latency
    assert_includes @log.string, "RedisClient::ReadTimeoutError"
    assert_not_includes @log.string, "secret-host"
  end

  test "failed reads are retried once per refresh interval and logged at most once a minute" do
    @source.failure = RuntimeError.new("down")
    backlog = backlog()
    3.times { backlog.shedding? }
    next_read
    backlog.shedding?

    assert_equal 2, @source.reads
    assert_equal 1, @log.string.scan("reading the ingest queue latency failed").size

    travel(Ingest::Backlog::LOG_INTERVAL)
    backlog.shedding?
    assert_equal 2, @log.string.scan("reading the ingest queue latency failed").size
  end

  test "a value older than a minute counts as unknown and admits" do
    backlog = backlog()
    @source.seconds_value = 300
    assert backlog.shedding?

    @source.failure = RuntimeError.new("down")
    travel(Ingest::Backlog::MAX_AGE - 1.second)
    assert backlog.shedding?

    travel(1.second)
    assert_not backlog.shedding?
    assert_nil backlog.latency
  end

  test "an unknown value never sheds" do
    @source.failure = RuntimeError.new("down")
    assert_not backlog.shedding?
  end

  test "shed_after 0 turns shedding off without reading the source" do
    backlog = backlog(shed_after: 0)
    @source.seconds_value = 10_000
    assert_not backlog.shedding?
    assert_equal 0, @source.reads
  end

  test "latency is still read when shedding is off, for the stale requeue" do
    @source.seconds_value = 900
    backlog = backlog(shed_after: 0)

    assert_equal 900.0, backlog.latency
    assert_not backlog.shedding?
  end

  test "logs when it starts and stops shedding" do
    backlog = backlog()
    @source.seconds_value = 134.4
    backlog.shedding?
    next_read
    @source.seconds_value = 12
    backlog.shedding?

    assert_includes @log.string, "started shedding events (ingest queue latency 134 s; sheds at 120 s, resumes below 30 s)"
    assert_includes @log.string, "stopped shedding events (ingest queue latency 12 s"
    assert_equal 2, @log.string.lines.size
  end

  test "the real source reads 0 outside the Sidekiq adapter" do
    backlog = Ingest::Backlog.new(shed_after: 1, resume_below: 0)
    assert_equal 0.0, backlog.latency
    assert_not backlog.shedding?
  end

  # Sets the boot-time thresholds, whatever the shell's environment set them to.
  def with_ingest_config(shed_after:, resume_below:)
    config = Rails.configuration.x.ingest
    previous = [ config.shed_after_seconds, config.resume_below_seconds, Ingest::Backlog.current ]
    config.shed_after_seconds = shed_after
    config.resume_below_seconds = resume_below
    Ingest::Backlog.current = nil
    yield
  ensure
    config.shed_after_seconds, config.resume_below_seconds, Ingest::Backlog.current = previous
  end

  test "by default, uses the boot-time thresholds" do
    with_ingest_config(shed_after: 40, resume_below: 20) do
      backlog = Ingest::Backlog.new(source: FakeLatency.new(40), logger: ActiveSupport::Logger.new(@log))
      assert backlog.shedding?
      assert_includes @log.string, "sheds at 40 s, resumes below 20 s"
    end
  end

  test "the process-wide instance is built once" do
    with_ingest_config(shed_after: 40, resume_below: 20) do
      assert_same Ingest::Backlog.current, Ingest::Backlog.current
    end
  end
end
