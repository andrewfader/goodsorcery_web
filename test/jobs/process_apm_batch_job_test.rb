require "test_helper"
require_relative "../models/apm/apm_test_support"

class ProcessApmBatchJobTest < ActiveJob::TestCase
  include ApmFixtureClock

  include ApmTestSupport

  test "processes the batch by id on the apm queue" do
    id = store_batch(metrics_body)
    assert_equal "apm", ProcessApmBatchJob.new(id).queue_name
    ProcessApmBatchJob.perform_now(id)
    assert ApmInboundBatch.find(id).processed?
  end

  test "a missing or processed batch is a no-op" do
    assert_nothing_raised { ProcessApmBatchJob.perform_now(-1) }
  end

  test "a null byte in a transaction's source is dropped from metrics and traces" do
    metrics = metrics_body([ metrics_transaction(name: "OrdersController#show", source: "app/controllers/orders\u0000_controller.rb") ])
    traces = traces_body([ trace_hash(name: "CartsController#show", source: "app/controllers/carts\u0000_controller.rb") ])
    ProcessApmBatchJob.perform_now(store_batch(metrics))
    ProcessApmBatchJob.perform_now(store_batch(traces, kind: "traces"))

    transactions = projects(:storefront).apm_transactions
    assert_equal "app/controllers/orders_controller.rb", transactions.find_by!(name: "OrdersController#show").source_file
    assert_equal "app/controllers/carts_controller.rb", transactions.find_by!(name: "CartsController#show").source_file
  end

  test "a batch Postgres can't store is discarded instead of retried" do
    id = store_batch(metrics_body)
    with_failing_upsert(ArgumentError.new("string contains null byte")) do
      assert_nothing_raised { ProcessApmBatchJob.perform_now(id) }
    end
    batch = ApmInboundBatch.find(id)
    assert batch.processed?
    assert_nil batch.body
  end

  test "other argument errors still raise" do
    id = store_batch(metrics_body)
    with_failing_upsert(ArgumentError.new("wrong number of arguments")) do
      assert_raises(ArgumentError) { ProcessApmBatchJob.perform_now(id) }
    end
    assert_not ApmInboundBatch.find(id).processed?
  end

  test "database errors are re-raised without their message" do
    id = store_batch(metrics_body)
    failing = ->(*) { raise ActiveRecord::StatementInvalid, "value mara@example.com violates" }
    Apm::BatchProcessor.class_eval { alias_method :original_process, :process }
    Apm::BatchProcessor.define_method(:process, &failing)
    error = assert_raises(Apm::ProcessingFailed) { ProcessApmBatchJob.perform_now(id) }
    assert_not_includes error.message, "mara"
    assert_includes error.message, id.to_s
  ensure
    Apm::BatchProcessor.class_eval do
      alias_method :process, :original_process
      remove_method :original_process
    end
  end

  private
    def with_failing_upsert(error)
      Apm::StatsUpsert.class_eval { alias_method :original_upsert, :upsert }
      Apm::StatsUpsert.define_method(:upsert) { |*| raise error }
      yield
    ensure
      Apm::StatsUpsert.class_eval do
        alias_method :upsert, :original_upsert
        remove_method :original_upsert
      end
    end
end
