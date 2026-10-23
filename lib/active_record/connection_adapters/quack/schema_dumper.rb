require "active_record/connection_adapters/abstract/schema_dumper"

module ActiveRecord
  module ConnectionAdapters
    module Quack
      class SchemaDumper < ConnectionAdapters::SchemaDumper
        private
        def tables(stream)
          # Sequence-backed primary keys must survive loading schema.rb into a
          # fresh database, including sequences supplied by the application.
          @connection.select_values(<<~SQL, "SCHEMA").each do |sql|
            SELECT sql FROM duckdb_sequences()
            WHERE database_name = current_database() AND schema_name = current_schema()
            ORDER BY sequence_name
          SQL
            statement = sql.sub(/\ACREATE SEQUENCE\b/i, "CREATE SEQUENCE IF NOT EXISTS")
            stream.puts "  execute #{statement.inspect}"
          end
          stream.puts
          super
        end
      end
    end
  end
end
