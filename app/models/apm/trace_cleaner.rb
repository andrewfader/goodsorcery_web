# The string cleaning applied to every captured trace string
# (docs/ARCHITECTURE.md §13.5): null bytes dropped, capped, scrubbed of secrets by
# Ingest::Scrubber; paths lose any leading scheme://user:pass@host or //host,
# their query string and fragment, hosts their user:pass@ part, files are
# made app-relative, SQL is re-normalised.
class Apm::TraceCleaner
  def initialize(scrubber: Ingest::Scrubber.new)
    @scrubber = scrubber
    @sql_scrub = Apm::SqlScrub.new(scrubber:)
    @paths = Ingest::PathNormalizer.new
  end

  # Null bytes go first: Postgres can't store them in a text column, and
  # dropping them before scrubbing means one can't split a secret apart.
  def text(value, max)
    @scrubber.scrub_text(value.delete("\u0000")).first(max) if value.is_a?(String)
  end

  ORIGIN = %r{\A(?:[a-z][a-z0-9+.-]*:)?//[^/?#]*}i

  def path(value)
    return unless value.is_a?(String)

    bare = value.split(/[?#]/, 2).first.to_s.sub(ORIGIN, "")
    text(bare.empty? ? "/" : bare, Apm::Limits::PATH)
  end

  def host(value)
    text(value.sub(/\A[^@\/]*@/, ""), Apm::Limits::HOST) if value.is_a?(String)
  end

  def file(value)
    text(@paths.normalize(value), Apm::Limits::FILE)
  end

  def sql(value)
    @sql_scrub.scrub(value) if value.is_a?(String)
  end
end
