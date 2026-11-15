require "test_helper"

class IngestSheddingTest < ActiveSupport::TestCase
  def parse(shed_after = nil, resume_below = nil)
    IngestShedding.from_env({ "GOODSORCERY_INGEST_SHED_AFTER_SECONDS" => shed_after,
                              "GOODSORCERY_INGEST_RESUME_BELOW_SECONDS" => resume_below }.compact)
  end

  def assert_thresholds(expected, shedding)
    assert_equal expected, [ shedding.shed_after, shedding.resume_below ]
  end

  test "defaults to shedding at 120 s and resuming below 30 s" do
    assert_thresholds [ 120, 30 ], parse
    assert_thresholds [ 120, 30 ], parse(" ", "")
    assert_nil parse.problem
  end

  test "reads valid whole numbers of seconds" do
    assert_thresholds [ 600, 60 ], parse("600", " 60 ")
    assert_thresholds [ 45, 40 ], parse("45", "40")
    assert_thresholds [ 120, 1 ], parse(nil, "1")
    assert_nil parse("600", "60").problem
  end

  test "an unset resume value is 30, or half of shed-after when that is less" do
    assert_thresholds [ 600, 30 ], parse("600")
    assert_thresholds [ 60, 30 ], parse("60")
    assert_thresholds [ 45, 22 ], parse("45")
    assert_thresholds [ 20, 10 ], parse("20")
    assert_thresholds [ 3, 1 ], parse("3")
    assert_thresholds [ 2, 1 ], parse("2", " ")
    assert_nil parse("20").problem
  end

  test "0 turns shedding off, whatever the resume value" do
    assert_equal 0, parse("0").shed_after
    assert_equal 0, parse("0", "nope").shed_after
    assert_nil parse("0", "nope").problem
  end

  test "invalid values fall back to both defaults and say why" do
    {
      [ "two minutes", nil ] => "GOODSORCERY_INGEST_SHED_AFTER_SECONDS must be a whole number",
      [ "-5", nil ] => "GOODSORCERY_INGEST_SHED_AFTER_SECONDS must be a whole number",
      [ "1.5", nil ] => "GOODSORCERY_INGEST_SHED_AFTER_SECONDS must be a whole number",
      [ "600", "abc" ] => "GOODSORCERY_INGEST_RESUME_BELOW_SECONDS must be a whole number",
      [ "600", "0" ] => "must be at least 1 and less than GOODSORCERY_INGEST_SHED_AFTER_SECONDS",
      [ "60", "60" ] => "must be at least 1 and less than",
      [ "20", "30" ] => "must be at least 1 and less than",
      [ nil, "120" ] => "must be at least 1 and less than",
      [ "1", nil ] => "GOODSORCERY_INGEST_SHED_AFTER_SECONDS must be 0 (off) or at least 2"
    }.each do |(shed_after, resume_below), problem|
      shedding = parse(shed_after, resume_below)
      assert_thresholds [ 120, 30 ], shedding
      assert_includes shedding.problem, problem, "for #{shed_after.inspect}, #{resume_below.inspect}"
    end
  end
end
