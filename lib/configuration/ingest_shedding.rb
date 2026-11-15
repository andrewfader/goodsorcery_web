# The thresholds of backlog-aware ingest admission (Ingest::Backlog), read
# once at boot. Ingest starts answering 429 server_busy once the oldest job
# in the ingest queue has waited GOODSORCERY_INGEST_SHED_AFTER_SECONDS (120)
# and stops once it waits less than GOODSORCERY_INGEST_RESUME_BELOW_SECONDS.
# A shed-after of 0 turns shedding off.
#
# An unset resume value follows the shed-after value: 30, or half of
# shed-after when that is less (whole seconds), so setting only a low
# shed-after works as asked.
#
# Anything else that isn't a whole number of seconds, a shed-after of 1, or a
# resume value that isn't between 1 and shed-after - 1, falls back to both
# defaults; #problem says why, so boot can warn instead of refusing to start.
#
#   shedding = IngestShedding.from_env(ENV)
#   shedding.shed_after   # => 120
#   shedding.resume_below # => 30
class IngestShedding
  SHED_AFTER = "GOODSORCERY_INGEST_SHED_AFTER_SECONDS".freeze
  RESUME_BELOW = "GOODSORCERY_INGEST_RESUME_BELOW_SECONDS".freeze
  DEFAULT_SHED_AFTER = 120
  DEFAULT_RESUME_BELOW = 30

  def self.from_env(env) = new(env[SHED_AFTER], env[RESUME_BELOW])

  attr_reader :shed_after, :resume_below, :problem

  def initialize(shed_after, resume_below)
    shed = seconds(shed_after, DEFAULT_SHED_AFTER)
    resume = seconds(resume_below, default_resume_below(shed))
    @problem = problem_with(shed, resume)
    @shed_after, @resume_below = @problem ? [ DEFAULT_SHED_AFTER, DEFAULT_RESUME_BELOW ] : [ shed, resume ]
  end

  private
    # The default when blank; nil when not a whole number.
    def seconds(value, default)
      text = value.to_s.strip
      return default if text.empty?

      Integer(text, 10) if text.match?(/\A\d+\z/)
    end

    def default_resume_below(shed)
      shed.nil? ? DEFAULT_RESUME_BELOW : [ DEFAULT_RESUME_BELOW, shed / 2 ].min.clamp(1..)
    end

    def problem_with(shed, resume)
      return "#{SHED_AFTER} must be a whole number of seconds (0 turns shedding off)" if shed.nil?
      return if shed.zero?
      return "#{SHED_AFTER} must be 0 (off) or at least 2" if shed == 1
      return "#{RESUME_BELOW} must be a whole number of seconds" if resume.nil?

      "#{RESUME_BELOW} must be at least 1 and less than #{SHED_AFTER}" unless resume.between?(1, shed - 1)
    end
end
