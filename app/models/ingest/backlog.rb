# Backlog-aware ingest admission (docs/ARCHITECTURE.md §2.1.3). When the
# ingest queue falls too far behind, the event endpoints answer 429
# server_busy (IngestEndpoint#shed_when_backlogged) instead of storing events
# that would wait for hours or be deleted unprocessed after a day.
#
# The signal is the age of the oldest waiting ingest job (Ingest::QueueLatency).
# Hysteresis, per process: shedding starts at shed_after seconds and stops
# below resume_below (config.x.ingest, read at boot; a shed_after of 0 turns
# it off). Between a stop and the next start the oldest job has to age from
# under resume_below to shed_after, so the start/stop log lines can't flood.
#
# Requests never queue up behind it: the latency is read at most every
# REFRESH_INTERVAL, by the one thread that wins a try_lock (the others use the
# last value without waiting), within Ingest::QueueLatency's timeouts (about
# 1 s for a stalled Redis). A failed read keeps the last value, and a value
# older than MAX_AGE counts as unknown, which admits (fail open: with Redis
# down the enqueue fails anyway). Readers see immutable samples, so it is
# safe across Puma threads.
class Ingest::Backlog
  REFRESH_INTERVAL = 5.seconds
  MAX_AGE = 60.seconds
  RETRY_AFTER = 30
  LOG_INTERVAL = 1.minute

  Sample = Data.define(:seconds, :read_at)

  class << self
    # The process-wide instance, so the memo and the hysteresis are shared by
    # every request of the process. Two threads racing on the first call may
    # each build one; one is kept, which is harmless.
    def current = @current ||= new

    # Tests swap in an instance with a fake source.
    attr_writer :current
  end

  def initialize(shed_after: Rails.configuration.x.ingest.shed_after_seconds,
                 resume_below: Rails.configuration.x.ingest.resume_below_seconds,
                 source: Ingest::QueueLatency.new, logger: Rails.logger)
    @shed_after = shed_after
    @resume_below = resume_below
    @source = source
    @logger = logger
    @lock = Mutex.new
    @shedding = false
  end

  # Whether ingest should turn events away now.
  def shedding?
    return false unless enabled?

    refresh_when_due
    @shedding && known?(@sample)
  end

  # Seconds the oldest waiting ingest job has waited, or nil when unknown.
  def latency
    refresh_when_due
    sample = @sample
    sample.seconds if known?(sample)
  end

  private
    def enabled? = @shed_after.positive?

    def known?(sample) = !sample.nil? && sample.read_at > MAX_AGE.ago

    def refresh_due? = @attempted_at.nil? || @attempted_at <= REFRESH_INTERVAL.ago

    # Single flight: a thread that doesn't get the lock goes on with the last value.
    def refresh_when_due
      return unless refresh_due? && @lock.try_lock

      refresh if refresh_due?
    ensure
      @lock.unlock if @lock.owned?
    end

    def refresh
      @attempted_at = Time.current
      record Sample.new(seconds: @source.seconds.to_f, read_at: @attempted_at)
    rescue StandardError => error
      warn_read_failed(error)
    end

    def record(sample)
      @sample = sample
      return unless enabled?

      if @shedding && sample.seconds < @resume_below
        switch(false, sample)
      elsif !@shedding && sample.seconds >= @shed_after
        switch(true, sample)
      end
    end

    def switch(shedding, sample)
      @shedding = shedding
      message = "Ingest backlog: #{shedding ? "started" : "stopped"} shedding events (ingest queue latency " \
                "#{sample.seconds.round} s; sheds at #{@shed_after} s, resumes below #{@resume_below} s)"
      shedding ? @logger.warn(message) : @logger.info(message)
    end

    # By error class only, at most once a LOG_INTERVAL.
    def warn_read_failed(error)
      return if @warned_at && @warned_at > LOG_INTERVAL.ago

      @warned_at = Time.current
      @logger.warn("Ingest backlog: reading the ingest queue latency failed (#{error.class.name}); " \
                   "using the last value, admitting once it is over #{MAX_AGE.to_i} s old")
    end
end
