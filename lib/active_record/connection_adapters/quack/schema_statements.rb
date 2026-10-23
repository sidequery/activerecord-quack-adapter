module ActiveRecord
  module ConnectionAdapters
    module Quack
      class TableDefinition < ConnectionAdapters::TableDefinition
        def foreign_key(*)
          raise ActiveRecord::StatementInvalid, "Quack foreign-key migration helpers are unsupported; use explicit DuckDB SQL"
        end

        def check_constraint(*)
          raise ActiveRecord::StatementInvalid, "Quack check-constraint migration helpers are unsupported; use explicit DuckDB SQL"
        end
      end

      module SchemaStatements
        def add_foreign_key(*)
          raise ActiveRecord::StatementInvalid, "Quack foreign-key migration helpers are unsupported; use explicit DuckDB SQL"
        end
        alias remove_foreign_key add_foreign_key

        def add_check_constraint(*)
          raise ActiveRecord::StatementInvalid, "Quack check-constraint migration helpers are unsupported; use explicit DuckDB SQL"
        end
        alias remove_check_constraint add_check_constraint

        def create_table(table_name, id: :primary_key, primary_key: nil, **options, &block)
          if [:primary_key, :bigint, :integer].include?(id) && !primary_key.is_a?(Array) && !options[:as] && !options.key?(:default)
            parts = ::Quack::SQL.identifier_parts(table_name)
            sequence = parts[0...-1] + ["#{parts.last}_#{primary_key || 'id'}_seq"]
            sequence_name = sequence.map { |part| quote_column_name(part) }.join(".")
            execute("CREATE SEQUENCE IF NOT EXISTS #{sequence_name}")
            id = {type: id == :integer ? :integer : :bigint, default: -> { "nextval(#{quote(sequence_name)})" }}
          end
          super(table_name, id: id, primary_key: primary_key, **options, &block)
        end

        def primary_keys(table_name)
          row = internal_exec_query("SELECT constraint_column_names FROM duckdb_constraints() WHERE #{catalog_scope(table_name)} AND constraint_type = 'PRIMARY KEY'", "SCHEMA").first
          row ? row.fetch("constraint_column_names") : []
        end

        def indexes(table_name)
          internal_exec_query("SELECT index_name, is_unique, expressions, sql FROM duckdb_indexes() WHERE #{catalog_scope(table_name)}", "SCHEMA").map do |row|
            expressions = row.fetch("sql")[/\bON\b.*?\((.*)\)\s*;?\z/im, 1]
            parts = expressions.to_s.split(/,\s*/)
            simple = parts.all? { |part| part.match?(/\A(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z_0-9]*)\z/) }
            columns = simple ? parts.map { |part| part.delete_prefix('"').delete_suffix('"').gsub('""', '"') } : expressions
            IndexDefinition.new(table_name, row.fetch("index_name"), row.fetch("is_unique"), columns)
          end
        end

        def rename_table(table_name, new_name, **)
          execute("ALTER TABLE #{quote_table_name(table_name)} RENAME TO #{quote_column_name(new_name)}")
          schema_cache.clear_data_source_cache!(table_name.to_s)
          schema_cache.clear_data_source_cache!(new_name.to_s)
        end

        def change_column_default(table_name, column_name, default_or_changes)
          default = extract_new_default_value(default_or_changes)
          column = column_for(table_name, column_name)
          execute("ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} SET DEFAULT #{quote_default_expression(default, column)}")
        end

        def change_column_null(table_name, column_name, null, default = nil)
          validate_change_column_null_argument!(null)
          unless null || default.nil?
            execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)} = #{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
          end
          execute("ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} #{null ? 'DROP' : 'SET'} NOT NULL")
        end

        def change_column(table_name, column_name, type, **options)
          execute("ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} TYPE #{type_to_sql(type, **options)}")
          change_column_default(table_name, column_name, options[:default]) if options.key?(:default)
          change_column_null(table_name, column_name, options[:null]) if options.key?(:null)
        end

        def rename_column(table_name, column_name, new_column_name)
          execute("ALTER TABLE #{quote_table_name(table_name)} RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}")
        end

        def remove_index(table_name, column_name = nil, **options)
          return if options[:if_exists] && !index_exists?(table_name, column_name, **options)
          name = index_name_for_remove(table_name, column_name, options)
          execute("DROP INDEX #{quote_table_name(name)}")
        end

        def type_to_sql(type, limit: nil, **options)
          if type.to_s == "integer"
            return {1 => "TINYINT", 2 => "SMALLINT", 4 => "INTEGER", 8 => "BIGINT"}.fetch(limit || 4) { raise ArgumentError, "unsupported integer limit: #{limit}" }
          end
          super(type, limit: limit, **options)
        end

        def create_schema_dumper(options)
          Quack::SchemaDumper.create(self, options)
        end

        private
        def create_table_definition(name, **options)
          Quack::TableDefinition.new(self, name, **options)
        end

        def catalog_scope(name)
          parts = ::Quack::SQL.identifier_parts(name)
          table = parts.pop
          schema = parts.pop
          catalog = parts.pop
          "database_name = #{catalog ? quote(catalog) : 'current_database()'} AND schema_name = #{schema ? quote(schema) : 'current_schema()'} AND table_name = #{quote(table)}"
        end

        def data_source_sql(name = nil, type: nil)
          parts = name ? ::Quack::SQL.identifier_parts(name) : []
          table, schema, catalog = parts.reverse
          sql = +"SELECT table_name FROM information_schema.tables WHERE table_catalog = #{catalog ? quote(catalog) : 'current_database()'} AND table_schema = #{schema ? quote(schema) : 'current_schema()'}"
          sql << " AND table_name = #{quote(table)}" if table
          sql << " AND table_type = #{quote(type)}" if type
          sql << " ORDER BY table_name"
        end

        def column_definitions(table_name)
          internal_exec_query("SELECT column_name, data_type, column_default, is_nullable FROM duckdb_columns() WHERE #{catalog_scope(table_name)} ORDER BY column_index", "SCHEMA").to_a
        end

        def new_column_from_field(_table_name, field, _definitions)
          sql_type = field.fetch("data_type")
          metadata = fetch_type_metadata(sql_type)
          cast_type = lookup_cast_type(sql_type)
          raw_default = field["column_default"]
          literal = raw_default && raw_default.match?(/\A(?:NULL|true|false|[-+]?\d+(?:\.\d+)?|'(?:[^']|'')*'(?:::[\w ]+)?)\z/i)
          default = if literal
            text = raw_default.sub(/::[\w ]+\z/, "")
            text = text[1...-1].gsub("''", "'") if text.start_with?("'")
            raw_default.casecmp?("NULL") ? nil : text
          end
          default_function = raw_default unless literal
          args = [field.fetch("column_name"), default, metadata, field.fetch("is_nullable"), default_function]
          args.insert(1, cast_type) if ActiveRecord.gem_version >= Gem::Version.new("8.1")
          Column.new(*args)
        end
      end
    end
  end
end
