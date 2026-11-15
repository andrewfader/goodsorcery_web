# How Ingest::CounterTotals are written to, and read back from, the fields
# of the counter buffer's Valkey hash (docs/ARCHITECTURE.md §2.5.2). Field
# names hold ids, hour starts (epoch seconds), environment names, tag keys
# (IssueTagCount::KEY_FORMAT, no colon) and tag value digests (HMACs, or
# "other") only; values are numbers. Never a tag value, an identity or
# anything else captured with an error.
#
#   t:<issue_id>:<key>:<value_digest>         stored tag value count (HINCRBY)
#   ih:<issue_id>:<hour>                      issue hourly count (HINCRBY)
#   e:<issue_id>                              events (HINCRBY)
#   u:<issue_id>                              new affected users (HINCRBY)
#   l:<issue_id>                              last seen, epoch microseconds (kept as a maximum)
#   ph:<project_id>:<hour>:<environment>      project hourly count (HINCRBY)
module Ingest::CounterFields
  module_function

  # { field => increment } for HINCRBY.
  def increments(totals)
    fields = {}
    totals.tags.each { |(id, key, digest), count| fields["t:#{id}:#{key}:#{digest}"] = count }
    totals.issue_hours.each { |(id, hour), count| fields["ih:#{id}:#{hour.to_i}"] = count }
    totals.issues.each do |id, counts|
      fields["e:#{id}"] = counts.events
      fields["u:#{id}"] = counts.users if counts.users.positive?
    end
    totals.project_hours.each { |(id, environment, hour), count| fields["ph:#{id}:#{hour.to_i}:#{environment}"] = count }
    fields
  end

  # { field => value } kept as a maximum.
  def maxima(totals)
    totals.issues.to_h { |id, counts| [ "l:#{id}", microseconds(counts.last_seen_at) ] }
  end

  # The totals that (field, value) pairs read back from the hash hold.
  # Unknown fields are skipped.
  def decode(fields)
    fields.each_with_object(Ingest::CounterTotals.new) { |(field, value), totals| decode_field(totals, field, value.to_i) }
  end

  def decode_field(totals, field, value)
    kind, id, second, third = field.split(":", 4)
    case kind
    when "t" then totals.tags[[ id.to_i, second, third ]] = value
    when "ih" then totals.issue_hours[[ id.to_i, Time.zone.at(second.to_i) ]] = value
    when "e" then totals.issue(id.to_i).events = value
    when "u" then totals.issue(id.to_i).users = value
    when "l" then totals.issue(id.to_i).last_seen_at = Time.zone.at(Rational(value, 1_000_000))
    when "ph" then totals.project_hours[[ id.to_i, third, Time.zone.at(second.to_i) ]] = value
    end
  end

  def microseconds(time) = (time.to_r * 1_000_000).to_i
end
