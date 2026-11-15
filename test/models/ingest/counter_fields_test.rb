require "test_helper"

class Ingest::CounterFieldsTest < ActiveSupport::TestCase
  setup do
    @hour = TimeSeries.align(Time.current, 1.hour)
    @seen = @hour + 12.minutes + 0.345678r
    @digest = IssueTagCount.value_digest("release", "v1.2.3")
    @totals = Ingest::CounterTotals.new
    add(occurred_at: @seen, issue_id: 7, new_user: true, tag_rows: [ [ 7, "release", @digest ], [ 7, "browser.name", "other" ] ])
    add(occurred_at: @hour, issue_id: 7, tag_rows: [ [ 7, "release", @digest ] ])
    add(environment: "staging", occurred_at: @hour)
  end

  test "fields hold ids, hour starts, environment names, tag keys and value digests, and values are numbers" do
    assert_equal({ "t:7:release:#{@digest}" => 2, "t:7:browser.name:other" => 1, "e:7" => 2, "u:7" => 1,
                   "ih:7:#{@hour.to_i}" => 2, "ph:3:#{@hour.to_i}:eu-west" => 2, "ph:3:#{@hour.to_i}:staging" => 1 },
                 Ingest::CounterFields.increments(@totals))
    assert_equal({ "l:7" => (@seen.to_r * 1_000_000).to_i }, Ingest::CounterFields.maxima(@totals))
  end

  test "decoding what the store returns gives the totals back, to the microsecond" do
    fields = Ingest::CounterFields.increments(@totals).merge(Ingest::CounterFields.maxima(@totals)).transform_values(&:to_s)
    decoded = Ingest::CounterFields.decode(fields.merge("future:1" => "5").to_a)

    assert_equal @totals.issues.transform_values(&:to_a), decoded.issues.transform_values(&:to_a)
    assert_equal @totals.issue_hours, decoded.issue_hours
    assert_equal @totals.project_hours, decoded.project_hours
    assert_equal @totals.tags, decoded.tags
  end

  private
    def add(environment: "eu-west", **event)
      @totals.add_event(project_id: 3, environment:, received_at: @hour + 30.minutes, **event)
    end
end
