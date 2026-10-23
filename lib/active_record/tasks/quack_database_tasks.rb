require "active_record/tasks/database_tasks"

module ActiveRecord
  module Tasks
    parent = defined?(AbstractTasks) ? AbstractTasks : Object
    class QuackDatabaseTasks < parent
      def self.using_database_configurations? = true

      def initialize(config, *)
        @configuration_hash = config.respond_to?(:configuration_hash) ? config.configuration_hash : config
        super(config) if defined?(AbstractTasks)
      end

      def create
        require "active_record/connection_adapters/quack_adapter"
        config = @configuration_hash.symbolize_keys
        connection = ConnectionAdapters::QuackAdapter.new_client(config)
        begin
          connection.execute("USE #{ConnectionAdapters::QuackAdapter.quote_table_name(config[:catalog])}") if config[:catalog]
          connection.execute("SELECT 1")
        ensure
          connection.close
        end
        # The endpoint's database is provisioned by its server operator.
        raise ActiveRecord::DatabaseAlreadyExists
      end

      def drop
        raise DatabaseNotSupported, "Quack connects to an existing remote database; provision or remove it on the server"
      end
      alias purge drop

      def structure_dump(*)
        raise DatabaseNotSupported, "Quack supports schema.rb; use schema_format = :ruby"
      end
      alias structure_load structure_dump
      def charset = "UTF-8"
      def collation = nil
    end

    DatabaseTasks.register_task(/\Aquack\z/, QuackDatabaseTasks)
  end
end
