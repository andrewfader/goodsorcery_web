require "test_helper"

# Production Action Cable reads REDIS_CABLE_URL, then REDIS_URL, so installs
# that set only REDIS_URL keep working when the cable server is split out.
class CableConfigTest < ActiveSupport::TestCase
  KEYS = %w[REDIS_CABLE_URL REDIS_URL].freeze

  setup { @previous = ENV.to_h.slice(*KEYS) }
  teardown { KEYS.each { ENV[it] = @previous[it] } }

  test "uses REDIS_CABLE_URL when it is set" do
    ENV["REDIS_CABLE_URL"] = "redis://cable.example.test:6379/0"
    ENV["REDIS_URL"] = "redis://jobs.example.test:6379/0"

    assert_equal "redis://cable.example.test:6379/0", production_cable[:url]
  end

  test "falls back to REDIS_URL" do
    ENV.delete("REDIS_CABLE_URL")
    ENV["REDIS_URL"] = "redis://jobs.example.test:6379/0"

    assert_equal "redis://jobs.example.test:6379/0", production_cable[:url]
  end

  test "falls back to the local default without either" do
    KEYS.each { ENV.delete(it) }

    assert_equal "redis://localhost:6379/1", production_cable[:url]
  end

  test "keeps the redis adapter and channel prefix" do
    assert_equal "redis", production_cable[:adapter]
    assert_equal "goodsorcery_web_production", production_cable[:channel_prefix]
  end

  private
    def production_cable
      Rails.application.config_for(:cable, env: "production")
    end
end
