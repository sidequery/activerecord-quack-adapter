require_relative "test_helper"
require "activerecord-quack-adapter"
require "stringio"

class MigrationTest < Minitest::Test
  def setup
    skip "set QUACK_TEST_URI to run live integration tests" unless ENV["QUACK_TEST_URI"]
    ActiveRecord::Base.establish_connection(adapter: "quack", uri: ENV.fetch("QUACK_TEST_URI"), auth_token: ENV.fetch("QUACK_TEST_TOKEN", "quack-ruby-test"))
    @adapter = ActiveRecord::Base.connection
  end
  def teardown
    if @adapter
      @adapter.drop_table(:quack_migration_items, if_exists: true)
      @adapter.drop_table(:quack_tracked_items, if_exists: true)
      @adapter.execute("DROP SCHEMA IF EXISTS quack_ruby_schema CASCADE")
      ActiveRecord::Base.connection_pool.disconnect!
    end
  end
  def test_reversible_migration_and_schema_dump
    migration = Class.new(ActiveRecord::Migration[7.2]) do
      def change
        create_table(:quack_migration_items) do |table|
          table.string :label, null: false
          table.decimal :amount, precision: 12, scale: 3
        end
      end
    end.new
    migration.verbose = false
    migration.migrate(:up)
    assert @adapter.table_exists?(:quack_migration_items)
    @adapter.execute("INSERT INTO quack_migration_items (label) VALUES ('first')")
    assert_kind_of Integer, @adapter.select_value("SELECT id FROM quack_migration_items")
    output = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, output)
    refute_match(/Could not dump/, output.string)
    assert_includes output.string, 'create_table "quack_migration_items"'
    migration.migrate(:down)
    refute @adapter.table_exists?(:quack_migration_items)
    @adapter.execute('DROP SEQUENCE quack_migration_items_id_seq')
    ActiveRecord::Migration.suppress_messages { eval(output.string, TOPLEVEL_BINDING, "schema.rb") }
    @adapter.execute("INSERT INTO quack_migration_items (label) VALUES ('restored')")
    assert_kind_of Integer, @adapter.select_value("SELECT id FROM quack_migration_items")
  end
  def test_schema_qualified_names_and_readonly_connection
    @adapter.execute("CREATE SCHEMA quack_ruby_schema")
    @adapter.create_table('quack_ruby_schema."a.b"') { |table| table.string :label }
    assert @adapter.table_exists?('quack_ruby_schema."a.b"')
    assert_equal ["id"], @adapter.primary_keys('quack_ruby_schema."a.b"')
    assert_equal %w[id label], @adapter.columns('quack_ruby_schema."a.b"').map(&:name)
    ActiveRecord::Base.while_preventing_writes do
      assert_equal 42, @adapter.select_value("SELECT 42")
      assert_raises(ActiveRecord::ReadOnlyError) { @adapter.execute('INSERT INTO quack_ruby_schema."a.b" (label) VALUES (\'no\')') }
    end
  end

  def test_migration_context_tracks_versions_and_rolls_back
    pool = ActiveRecord::Base.connection_pool
    context = ActiveRecord::MigrationContext.new(File.join(__dir__, "fixtures/migrate"), pool.schema_migration, pool.internal_metadata)
    baseline_versions = context.get_all_versions
    ActiveRecord::Migration.suppress_messages { context.migrate }
    assert_includes context.get_all_versions, 20261023000000
    assert @adapter.table_exists?(:quack_tracked_items)
    ActiveRecord::Migration.suppress_messages { context.down(0) }
    refute @adapter.table_exists?(:quack_tracked_items)
    assert_equal baseline_versions, context.get_all_versions
    config = pool.db_config
    tasks = ActiveRecord::Tasks::QuackDatabaseTasks.new(config)
    assert_raises(ActiveRecord::DatabaseAlreadyExists) { tasks.create }
    assert_raises(ActiveRecord::Tasks::DatabaseNotSupported) { tasks.drop }
    assert_raises(ActiveRecord::StatementInvalid) { @adapter.add_foreign_key(:quack_migration_items, :quack_tracked_items) }
    assert_raises(ActiveRecord::StatementInvalid) { @adapter.add_check_constraint(:quack_migration_items, "id > 0") }
  end
end
