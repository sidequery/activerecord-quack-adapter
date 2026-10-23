module ActiveRecord
  module ConnectionAdapters
    module Quack
      # Rails 7.2 predates the perform_query/cast_result adapter hooks.
      module LegacyDatabaseStatements
        def internal_exec_query(sql, name = "SQL", binds = [], prepare: false, async: false, allow_retry: false)
          sql = transform_query(sql)
          check_if_write_query(sql)
          mark_transaction_written_if_write(sql)
          cast_result(legacy_raw_query(sql, name, binds, prepare: prepare, async: async))
        end

        def exec_delete(sql, name = "SQL", binds = [])
          sql = transform_query(sql)
          check_if_write_query(sql)
          mark_transaction_written_if_write(sql)
          affected_rows(legacy_raw_query(sql, name, binds))
        end
        alias exec_update exec_delete

        private
        def raw_execute(sql, name, async: false, allow_retry: false, materialize_transactions: true)
          legacy_raw_query(sql, name, [], async: async, materialize_transactions: materialize_transactions)
        end

        def legacy_raw_query(sql, name, binds, prepare: false, async: false, materialize_transactions: true)
          casted = type_casted_binds(binds)
          log(sql, name, binds, casted, async: async) do |payload|
            with_raw_connection(allow_retry: false, materialize_transactions: materialize_transactions) do |connection|
              perform_query(connection, sql, binds, casted, prepare: prepare, notification_payload: payload)
            end
          end
        end
      end
    end
  end
end
