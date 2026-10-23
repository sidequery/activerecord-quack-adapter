require "active_record/connection_adapters/abstract_adapter"
require "quack"
require_relative "quack/schema_statements"
require_relative "quack/schema_dumper"
require_relative "quack/legacy_database_statements"
require_relative "quack/value_type"

module ActiveRecord
  module ConnectionAdapters
    class QuackAdapter < AbstractAdapter
      ADAPTER_NAME = "Quack"
      include Quack::SchemaStatements
      include Quack::LegacyDatabaseStatements if ActiveRecord.gem_version < Gem::Version.new("8.0")

      NATIVE_DATABASE_TYPES = {
        primary_key: "BIGINT PRIMARY KEY",
        string: {name: "VARCHAR"}, text: {name: "VARCHAR"},
        integer: {name: "INTEGER"}, bigint: {name: "BIGINT"},
        float: {name: "DOUBLE"}, decimal: {name: "DECIMAL"},
        datetime: {name: "TIMESTAMP"}, timestamp: {name: "TIMESTAMP"},
        time: {name: "TIME"}, date: {name: "DATE"},
        binary: {name: "BLOB"}, boolean: {name: "BOOLEAN"},
        json: {name: "JSON"}, uuid: {name: "UUID"}
      }.freeze

      class << self
        def new_client(config)
          uri = config[:uri] || config[:database]
          unless uri
            host = config.fetch(:host, "localhost")
            host = "[#{host}]" if host.include?(":") && !host.start_with?("[")
            uri = "quack:#{host}:#{config.fetch(:port, 9494)}"
          end
          options = config.stringify_keys.slice(*::Quack::Connection::OPTIONS).symbolize_keys
          ::Quack::Connection.new(uri, **options)
        end

        def native_database_types = NATIVE_DATABASE_TYPES
        def quote_column_name(name) = ::Quack::SQL.identifier(name)
        def quote_table_name(name) = ::Quack::SQL.identifier_parts(name).map { |part| quote_column_name(part) }.join(".")

        private
        def initialize_type_map(map)
          super
          map.register_type(/\ATIMESTAMP(?:_S|_MS|_NS|TZ|TZ_NS| WITH TIME ZONE)?\z/i, Quack::DateTimeType.new)
          {"TINYINT" => 1, "SMALLINT" => 2, "INTEGER" => 4, "BIGINT" => 8,
           "UTINYINT" => 2, "USMALLINT" => 4, "UINTEGER" => 8,
           "UBIGINT" => 16, "HUGEINT" => 16, "UHUGEINT" => 32}.each do |name, limit|
            map.register_type(/\A#{name}\z/i, Type::Integer.new(limit: limit))
          end
          map.register_type(/\AUUID\z/i, Type::String.new)
          map.register_type(/(?:\[\d*\]\z|\A(?:STRUCT|TUPLE|MAP|UNION|VARIANT|BIT|GEOMETRY|BIGNUM)\b)/i, Quack::ValueType.new)
          map.register_type(/\AINTERVAL\z/i, Quack::ValueType.new)
        end
      end
      TYPE_MAP = Type::TypeMap.new.tap { |map| initialize_type_map(map) }

      def supports_ddl_transactions? = true
      def supports_savepoints? = false
      def supports_transaction_isolation? = false
      def supports_lazy_transactions? = true
      def supports_insert_returning? = true
      def supports_insert_on_duplicate_skip? = true
      def supports_insert_on_duplicate_update? = true
      def supports_insert_conflict_target? = true
      def supports_views? = true
      def supports_json? = true
      def supports_common_table_expressions? = true
      def supports_datetime_with_precision? = true
      def supports_explain? = true
      def native_database_types = NATIVE_DATABASE_TYPES
      def connected? = !!@raw_connection&.connected?

      def active?
        @lock.synchronize do
          return false unless connected?
          @raw_connection.query("SELECT 1")
          verified!
          true
        end
      rescue ::Quack::Error
        false
      end

      def disconnect!
        @lock.synchronize do
          super
          begin
            @raw_connection&.close
          rescue ::Quack::ConnectionError, ::Quack::ProtocolError, ::Quack::ForkError
            # Retire a failed or inherited connection without replaying SQL.
          ensure
            @raw_connection = nil
          end
        end
      end

      def quote_column_name(name) = self.class.quote_column_name(name)
      def quote_table_name(name) = self.class.quote_table_name(name)
      def quote_table_name_for_assignment(_table, attr) = quote_column_name(attr)
      def quote_string(text) = text.gsub("'", "''")
      def quoted_true = "TRUE"
      def quoted_false = "FALSE"
      def unquoted_true = true
      def unquoted_false = false
      def quoted_binary(value) = ::Quack::SQL.literal(value.to_s.b)
      # DuckDB resolves the bare CURRENT_TIMESTAMP keyword as a column inside
      # ON CONFLICT's update clause; the equivalent function avoids that.
      def high_precision_current_timestamp = Arel.sql("now()")

      def quote(value)
        case value
        when String, BigDecimal, Integer, Float
          ::Quack::SQL.literal(value)
        when ::Quack::Interval, ::Quack::TimeOfDay, ::Quack::InfiniteTemporal, Array, Hash
          ::Quack::SQL.literal(value)
        when ::Quack::Map, ::Quack::Union, ::Quack::Variant, ::Quack::Tuple, ::Quack::BitString, ::Quack::Geometry
          ::Quack::SQL.literal(value)
        else super
        end
      end

      def type_cast(value)
        case value
        when BigDecimal, ::Quack::Interval, ::Quack::TimeOfDay, ::Quack::InfiniteTemporal, Array, Hash,
             ::Quack::Map, ::Quack::Union, ::Quack::Variant, ::Quack::Tuple, ::Quack::BitString, ::Quack::Geometry
          value
        else super
        end
      end

      def quoted_time(value)
        inner = value.is_a?(Type::Time::Value) ? value.__getobj__ : value
        inner.is_a?(::Quack::TimeOfDay) ? inner.to_s : super
      end

      def quoted_date(value)
        # AbstractAdapter formats only six fractional digits, even for
        # TIMESTAMP_NS columns. DuckDB accepts all nine from a string bind.
        return super unless value.is_a?(Time) || value.is_a?(DateTime)
        normalized = if value.is_a?(Time)
          default_timezone == :utc ? value.getutc : value.getlocal
        else
          (default_timezone == :utc ? value.new_offset(0) : value).new_start(Date::GREGORIAN)
        end
        normalized.strftime("%Y-%m-%d %H:%M:%S.%N")
      end

      def begin_db_transaction
        internal_execute("BEGIN TRANSACTION", "TRANSACTION", materialize_transactions: false)
      end
      def commit_db_transaction
        internal_execute("COMMIT", "TRANSACTION", materialize_transactions: false)
      end
      def exec_rollback_db_transaction
        internal_execute("ROLLBACK", "TRANSACTION", materialize_transactions: false)
      end
      def create_savepoint(*)
        raise ActiveRecord::StatementInvalid, "DuckDB does not support savepoints"
      end

      READ_QUERY = AbstractAdapter.build_read_query_regexp(:describe, :show, :summarize, :explain)
      def write_query?(sql) = !READ_QUERY.match?(sql)

      # Adapted from Active Record's PostgreSQL adapter (MIT licensed).
      def build_insert_sql(insert)
        sql = +"INSERT #{insert.into} #{insert.values_list}"
        if insert.skip_duplicates?
          sql << " ON CONFLICT #{insert.conflict_target} DO NOTHING"
        elsif insert.update_duplicates?
          sql << " ON CONFLICT #{insert.conflict_target} DO UPDATE SET "
          if insert.raw_update_sql?
            sql << insert.raw_update_sql
          else
            sql << insert.touch_model_timestamps_unless { |column| "#{insert.model.quoted_table_name}.#{column} IS NOT DISTINCT FROM excluded.#{column}" }
            sql << insert.updatable_columns.map { |column| "#{column}=excluded.#{column}" }.join(",")
          end
        end
        sql << " RETURNING #{insert.returning}" if insert.returning
        sql
      end

      def explain(arel, binds = [], _options = [])
        internal_exec_query("EXPLAIN #{to_sql(arel, binds)}", "EXPLAIN", binds).rows.map(&:last).join("\n")
      end

      private
      if ActiveRecord.gem_version >= Gem::Version.new("8.0")
        def raw_execute(*args, **options)
          super(*args, **options.merge(allow_retry: false))
        end
      end
      def connect
        @raw_connection = self.class.new_client(@config)
      end
      def reconnect
        disconnect!
        connect
      end
      def get_database_version
        raw_connection.info.fetch("server_version").to_s.delete_prefix("v")
      end
      def configure_connection
        super
        @raw_connection.execute("USE #{quote_table_name(@config[:catalog])}") if @config[:catalog]
        @raw_connection.execute("SET schema = #{quote(@config[:schema])}") if @config[:schema]
        @raw_connection.execute("SET TimeZone = 'UTC'")
      end
      def perform_query(raw_connection, sql, binds, type_casted_binds, prepare:, notification_payload:, batch: false)
        # Binds are substituted with the same quoting rules as unprepared SQL.
        # No Rust pool: the AR pool owns each session and transaction affinity.
        query = ::Quack::SQL.bind(sql, type_casted_binds.empty? ? nil : type_casted_binds.map { |v| v.is_a?(Type::Binary::Data) ? v.to_s.b : v })
        result = raw_connection.query(query)
        verified!
        notification_payload[:row_count] = result.rows.length
        notification_payload[:affected_rows] = result.affected_rows
        result
      end
      def cast_result(result)
        types = {}
        result.column_metadata.each_with_index do |column, index|
          types[index] = types[column.fetch("name")] = result_type(column)
        end
        ActiveRecord::Result.new(result.columns, result.rows, types)
      end
      def affected_rows(result) = result.affected_rows
      def returning_column_values(result) = result.rows.first
      def result_type(column)
        return lookup_cast_type("JSON") if column["alias"]&.casecmp?("JSON")
        id = column.fetch("type")
        if id == "Decimal"
          return lookup_cast_type("DECIMAL(#{column.fetch('precision')},#{column.fetch('scale')})")
        end
        sql_type = {"TimestampTz" => "TIMESTAMP", "TimestampTzNs" => "TIMESTAMP", "TimestampSec" => "TIMESTAMP", "TimestampMs" => "TIMESTAMP", "TimestampNs" => "TIMESTAMP", "Double" => "DOUBLE", "SqlNull" => "NULL"}.fetch(id, id.upcase)
        lookup_cast_type(sql_type)
      end
      def translate_exception(exception, message:, sql:, binds:)
        klass = case exception
        when ::Quack::ConnectionError, ::Quack::ForkError then ActiveRecord::ConnectionFailed
        when ::Quack::TimeoutError then ActiveRecord::AdapterTimeout
        when ::Quack::ServerError
          case exception.message
          when /PRIMARY KEY|UNIQUE constraint|Duplicate key/i then ActiveRecord::RecordNotUnique
          when /NOT NULL constraint/i then ActiveRecord::NotNullViolation
          when /FOREIGN KEY constraint|violates foreign key/i then ActiveRecord::InvalidForeignKey
          when /Transaction conflict|Conflict on (?:update|tuple)/i then ActiveRecord::SerializationFailure
          end
        end
        klass ? klass.new(message, sql: sql, binds: binds, connection_pool: @pool) : super
      end
    end
  end
end
