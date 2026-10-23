require_relative "test_helper"
require_relative "type_cases"
require "activerecord-quack-adapter"

class QuackTypeValue < ActiveRecord::Base
  self.table_name = "quack_type_values"
end

class AdapterTypeMatrixTest < Minitest::Test
  def setup
    skip "set QUACK_TEST_URI to run live integration tests" unless ENV["QUACK_TEST_URI"]
    ActiveRecord::Base.establish_connection(adapter: "quack", uri: ENV.fetch("QUACK_TEST_URI"), auth_token: "quack-ruby-test")
    @adapter = ActiveRecord::Base.connection
  end

  def teardown
    if @adapter
      @adapter.execute("drop table if exists quack_type_values")
      ActiveRecord::Base.connection_pool.disconnect!
    end
  end

  QuackTypeCases::CASES.each do |name, type, expression, expected|
    define_method("test_model_and_result_#{name}") do
      skip "TIMESTAMPTZ_NS requires DuckDB 2" if type == "TIMESTAMPTZ_NS" && ENV.fetch("QUACK_TEST_VERSION").start_with?("1.")
      @adapter.execute("create table quack_type_values (id integer primary key, v #{type})")
      @adapter.execute("insert into quack_type_values values (1, (#{expression})::#{type}), (2, NULL)")
      @adapter.schema_cache.clear!
      QuackTypeValue.reset_column_information
      model_value = name == "json" ? {"x" => [1, nil, true]} : expected
      assert_equal model_value, QuackTypeValue.find(1).v
      assert_nil QuackTypeValue.find(2).v
      assert_equal [model_value, nil], @adapter.select_all("select v from quack_type_values order by id").cast_values
      value = QuackTypeValue.create!(id: 3, v: model_value)
      assert_equal model_value, value.reload.v
      assert_equal [1, 3], QuackTypeValue.where(v: model_value).order(:id).pluck(:id) unless %w[json struct list array nested_list interval geometry variant].include?(name)
    end
  end

  def test_model_tuple_roundtrip
    skip "DuckDB 1.5 rejects persisted unnamed tuples" if ENV.fetch("QUACK_TEST_VERSION").start_with?("1.")
    @adapter.execute("create table quack_type_values as select 1 id, row(42, 'é') v where false")
    @adapter.execute("alter table quack_type_values add primary key (id)")
    @adapter.schema_cache.clear!
    QuackTypeValue.reset_column_information
    value = Quack::Tuple.new([42, "é"])
    record = QuackTypeValue.create!(id: 1, v: value)
    assert_equal value, record.reload.v
    record.update!(v: Quack::Tuple.new([-1, "changed"]))
    assert_equal Quack::Tuple.new([-1, "changed"]), record.reload.v
  end

  def test_in_place_nested_attribute_updates_are_persisted
    @adapter.execute("create table quack_type_values (id INTEGER PRIMARY KEY, v STRUCT(items INTEGER[], m MAP(VARCHAR, INTEGER[])))")
    @adapter.schema_cache.clear!
    QuackTypeValue.reset_column_information
    record = QuackTypeValue.create!(id: 1, v: {"items" => [1], "m" => Quack::Map.new({"a" => [2]})})
    record.v["items"] << 3
    record.v["m"]["a"] << 4
    assert record.will_save_change_to_v?
    record.save!
    assert_equal({"items" => [1, 3], "m" => Quack::Map.new({"a" => [2, 4]})}, record.reload.v)
  end

  def test_datetime_input_uses_proleptic_gregorian_timestamp
    @adapter.execute("create table quack_type_values (id INTEGER PRIMARY KEY, v TIMESTAMPTZ)")
    @adapter.schema_cache.clear!
    QuackTypeValue.reset_column_information
    value = DateTime.new(1500, 1, 1, 12, 34, 56, "+05:30", Date::JULIAN)
    expected = Time.at((value.new_offset(0) - DateTime.new(1970, 1, 1)) * 86_400).utc
    record = QuackTypeValue.create!(id: 1, v: value)
    assert_equal expected, record.reload.v
    assert_equal [1], QuackTypeValue.where(v: value).pluck(:id)
  end
end
