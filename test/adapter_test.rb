require_relative "test_helper"
require "activerecord-quack-adapter"

class QuackWidget < ActiveRecord::Base
  self.table_name = "quack_ruby_widgets"
end

class AdapterTest < Minitest::Test
  def setup
    skip "set QUACK_TEST_URI to run live integration tests" unless ENV["QUACK_TEST_URI"]
    ActiveRecord::Base.establish_connection(adapter: "quack", uri: ENV.fetch("QUACK_TEST_URI"), auth_token: ENV.fetch("QUACK_TEST_TOKEN", "quack-ruby-test"), pool: 3)
    @adapter = ActiveRecord::Base.connection
    @adapter.create_table(:quack_ruby_widgets, force: true) do |table|
      table.string :name, null: false, default: "new"
      table.bigint :counter
      table.decimal :price, precision: 20, scale: 6
      table.boolean :enabled, default: true
      table.string :sentinel, default: "NULL"
      table.date :day
      table.datetime :recorded_at, precision: 6
      table.binary :payload
      table.timestamps
    end
    QuackWidget.reset_column_information
  end
  def teardown
    if @adapter
      @adapter.drop_table(:quack_ruby_widgets, if_exists: true)
      ActiveRecord::Base.connection_pool.disconnect!
    end
  end

  def test_crud_defaults_types_and_bound_queries
    time = Time.utc(2026, 10, 23, 1, 2, 3, 123456)
    widget = QuackWidget.create!(name: "héllo'\0 ?", counter: 2**60, price: BigDecimal("123.123456"), day: Date.new(2026, 10, 23), recorded_at: time, payload: "\x00\xff".b)
    assert_kind_of Integer, widget.id
    assert_equal "NULL", QuackWidget.new.sentinel
    record = QuackWidget.find(widget.id)
    assert_equal widget.name, record.name
    assert record.enabled
    assert_equal 2**60, record.counter
    assert_equal BigDecimal("123.123456"), record.price
    assert_equal time, record.recorded_at
    assert_equal widget.day, record.day
    assert_equal "\x00\xff".b, record.payload
    assert_equal 1, QuackWidget.where(id: widget.id..widget.id + 1).where("name = ?", widget.name).count
    assert_equal 1, QuackWidget.where(id: widget.id).update_all(name: "changed")
    assert_equal "changed", widget.reload.name
    widget.destroy!
    assert_equal 0, QuackWidget.count
  end

  def test_schema_discovery_and_returning
    assert @adapter.table_exists?(:quack_ruby_widgets)
    assert_equal ["id"], @adapter.primary_keys(:quack_ruby_widgets)
    counter = @adapter.columns(:quack_ruby_widgets).find { |col| col.name == "counter" }
    assert_equal :integer, counter.type
    assert_equal 8, counter.limit
    inserted = QuackWidget.insert_all!([{name: "a"}, {name: "b"}], returning: %w[id name])
    assert_equal %w[id name], inserted.columns
    assert_equal %w[a b], inserted.rows.map(&:last)
    assert_equal %w[a b], QuackWidget.order(:id).pluck(:name)
  end

  def test_transactions_errors_and_pool_affinity
    assert_raises(RuntimeError) do
      QuackWidget.transaction { QuackWidget.create!(name: "rollback"); raise "rollback" }
    end
    assert_equal 0, QuackWidget.count
    QuackWidget.transaction { QuackWidget.create!(name: "committed") }
    assert_equal 1, QuackWidget.count
    assert_raises(ActiveRecord::NotNullViolation) { QuackWidget.create!(name: nil) }
    id = QuackWidget.first.id
    assert_raises(ActiveRecord::RecordNotUnique) { QuackWidget.create!(id: id, name: "duplicate") }
    assert_equal 1, QuackWidget.count
    results = 2.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("create temp table pool_session (n integer)")
          connection.execute("insert into pool_session values (#{i})")
          connection.select_value("select n from pool_session")
        end
      end
    end.map(&:value)
    assert_equal [0, 1], results
  end

  def test_indexes_upserts_and_schema_changes
    @adapter.add_index(:quack_ruby_widgets, :name, unique: true)
    assert @adapter.index_exists?(:quack_ruby_widgets, :name, unique: true)
    widget = QuackWidget.create!(name: "unique", counter: 1)
    QuackWidget.upsert_all([{id: widget.id, name: "unique", counter: 2}], unique_by: :id)
    assert_equal 2, widget.reload.counter
    assert_equal [], QuackWidget.insert_all([{name: "unique"}]).rows
    @adapter.remove_index(:quack_ruby_widgets, :name)
    refute @adapter.index_exists?(:quack_ruby_widgets, :name)
    @adapter.add_column(:quack_ruby_widgets, :note, :string, default: "default")
    @adapter.rename_column(:quack_ruby_widgets, :note, :memo)
    @adapter.change_column_default(:quack_ruby_widgets, :memo, "updated")
    QuackWidget.reset_column_information
    assert_equal "updated", QuackWidget.create!(name: "other").reload.memo
    @adapter.remove_column(:quack_ruby_widgets, :memo)
  end
end
