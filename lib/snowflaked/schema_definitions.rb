# frozen_string_literal: true

module Snowflaked
  module SchemaDefinitions
    COMMENT = "snowflaked"

    module TableDefinition
      def snowflake(name, **options)
        options[:comment] = Snowflaked::SchemaDefinitions::COMMENT
        column(name, :snowflake, **options)
      end
    end

    module Table
      def snowflake(name, **options)
        options[:comment] = Snowflaked::SchemaDefinitions::COMMENT
        column(name, :snowflake, **options)
      end
    end
  end
end
