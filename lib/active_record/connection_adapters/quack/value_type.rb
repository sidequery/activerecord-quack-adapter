module ActiveRecord
  module ConnectionAdapters
    module Quack
      class DateTimeType < Type::DateTime
        def serialize_cast_value(value)
          # Active Support's DateTime#getutc converts calendar fields to Time.
          # Normalize the calendar first so Julian dates keep their instant.
          value = value.new_start(Date::GREGORIAN) if value.is_a?(::DateTime)
          super(value)
        end
      end

      class ValueType < Type::Value
        def cast(value) = ::Quack::Codec.copy(value)
        alias deserialize cast
        def mutable? = true
        def changed_in_place?(raw_old_value, new_value) = raw_old_value != new_value
      end
    end
  end
end
