# frozen_string_literal: true

module Snowflaked
  module SchemaDefinitions
    COMMENT = "snowflaked"

    module SnowflakeColumn
      def snowflake(name, **)
        column(name, :snowflake, comment: COMMENT, **)
      end
    end

    TableDefinition = SnowflakeColumn
    Table           = SnowflakeColumn
  end
end
