require "test_helper"
require_relative "../test_helpers/counter_buffer_test_helper"

class FlushIngestCountersJobTest < ActiveJob::TestCase
  include CounterBufferTestHelper

  teardown { clear_counter_store }

  test "does nothing without a configured store" do
    assert_nil Rails.configuration.x.counter_buffer_url
    assert_nothing_raised { FlushIngestCountersJob.perform_now }
  end

  test "runs on its own queue, without Sidekiq retries" do
    assert_equal "counters", FlushIngestCountersJob.queue_name
    assert_equal false, FlushIngestCountersJob.get_sidekiq_options["retry"]
  end

  test "flushes the configured store" do
    pool = counter_pool
    @counter_namespace = Ingest::CounterBuffer::NAMESPACE # the app's own keys: clear them afterwards
    issue = issues(:nomethod)
    Ingest::CounterBuffer.new(pool).add_event(project_id: issue.project_id, environment: "production",
                                              occurred_at: Time.current, received_at: Time.current, issue_id: issue.id,
                                              occurrence_id: 1)
    Rails.configuration.x.counter_buffer_url = counter_store_url

    assert_difference(-> { issue.reload.events_count }, 1) { FlushIngestCountersJob.perform_now }
  ensure
    Rails.configuration.x.counter_buffer_url = nil
  end
end
