require "active_record"
require_relative "active_record/tasks/quack_database_tasks"

ActiveRecord::ConnectionAdapters.register(
  "quack", "ActiveRecord::ConnectionAdapters::QuackAdapter",
  "active_record/connection_adapters/quack_adapter"
)
