# The ledger of buffered counter chunks already added to Postgres
# (docs/ARCHITECTURE.md §2.5.2). A flush records a chunk's id in the same
# transaction that applies it, so a retried or overlapping flush skips it.
# Ids and a time only.
class CreateCounterFlushes < ActiveRecord::Migration[8.1]
  def change
    create_table :counter_flushes, id: :uuid, default: nil do |t|
      t.datetime :created_at, null: false
      t.index :created_at
    end
  end
end
