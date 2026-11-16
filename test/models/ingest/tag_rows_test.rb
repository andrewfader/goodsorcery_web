require "test_helper"

class Ingest::TagRowsTest < ActiveSupport::TestCase
  setup { @issue = issues(:card_error) }

  def fill(key, values)
    IssueTagCount.insert_all(values.map do |value|
      { issue_id: @issue.id, key:, value_digest: IssueTagCount.value_digest(key, value), value:, count: 1 }
    end)
  end

  def rows(tags) = Ingest::TagRows.new(@issue.id, tags).to_a

  test "rows for every tag, sorted by key and digest" do
    result = rows("release" => "a1", "browser" => "Chrome")

    assert_equal %w[browser release], result.map { it[:key] }
    assert_equal IssueTagCount.value_digest("browser", "Chrome"), result.first[:value_digest]
  end

  test "a key at its value cap counts new values as Other values but keeps counting known ones" do
    fill("request_id", Array.new(IssueTagCount::VALUES_PER_KEY) { "req-#{it}" })

    assert_equal [ [ "other", "Other values" ] ], rows("request_id" => "req-new").map { it.values_at(:value_digest, :value) }
    assert_equal IssueTagCount.value_digest("request_id", "req-7"), rows("request_id" => "req-7").sole[:value_digest]
  end

  test "an issue at its key cap drops new keys but keeps counting known keys" do
    IssueTagCount::KEYS_PER_ISSUE.times { |n| fill("key#{n}", [ "v" ]) }

    assert_empty rows("brand_new" => "x")
    assert_equal [ "key3" ], rows("key3" => "another").map { it[:key] }
  end

  test "known values cost one query" do
    fill("browser", [ "Chrome" ])
    assert_queries_count(1) { rows("browser" => "Chrome") }
  end

  test "stored and new rows split the rows by whether the issue has the value, an existing Other values row counting as stored" do
    fill("browser", [ "Chrome" ])
    fill("request_id", Array.new(IssueTagCount::VALUES_PER_KEY) { "req-#{it}" })
    tag_rows = Ingest::TagRows.new(@issue.id, "browser" => "Chrome", "release" => "a1", "request_id" => "req-new")

    assert_equal %w[browser], tag_rows.stored_rows.map { it[:key] }
    assert_equal %w[release request_id], tag_rows.new_rows.map { it[:key] }, "the first Other values row is inserted"

    IssueTagCount.insert({ issue_id: @issue.id, key: "request_id", value_digest: IssueTagCount::OTHER_DIGEST,
                           value: IssueTagCount::OTHER_VALUE, count: 1 })
    later = Ingest::TagRows.new(@issue.id, "browser" => "Chrome", "request_id" => "req-newer")
    assert_equal [ [ "browser", IssueTagCount.value_digest("browser", "Chrome") ], [ "request_id", "other" ] ],
                 later.stored_rows.map { it.values_at(:key, :value_digest) }
    assert_empty later.new_rows
  end

  test "stored values still cost one query" do
    fill("browser", [ "Chrome" ])
    assert_queries_count(1) { Ingest::TagRows.new(@issue.id, "browser" => "Chrome").then { [ it.stored_rows, it.new_rows ] } }
  end

  test "the issue page reads capped keys as N+ values" do
    fill("request_id", Array.new(IssueTagCount::VALUES_PER_KEY) { "req-#{it}" })
    IssueTagCount.upsert_all(rows("request_id" => "req-new"), on_duplicate: Arel.sql("count = issue_tag_counts.count + 1"),
                             record_timestamps: false)

    key = IssueTagCount.distribution(@issue).sole
    assert key.capped?
    assert_equal IssueTagCount::VALUES_PER_KEY, key.distinct_count
    assert_equal IssueTagCount::VALUES_PER_KEY + 1, key.total
  end
end
