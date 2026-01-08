# frozen_string_literal: true

module Snowflaked
  module AdapterExtension
    SNOWFLAKE_TYPE = { name: "bigint" }.freeze

    def native_database_types
      super.merge(snowflake: SNOWFLAKE_TYPE)
    end

    module ClassMethods
      def native_database_types
        super.merge(snowflake: SNOWFLAKE_TYPE)
      end
    end

    def self.prepended(base)
      base.singleton_class.prepend(ClassMethods)
    end
  end
end
