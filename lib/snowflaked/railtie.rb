# frozen_string_literal: true

require "rails/railtie"

module Snowflaked
  class Railtie < Rails::Railtie
    initializer "snowflaked.register_type", after: "active_record.initialize_database" do
      ActiveSupport.on_load(:active_record) do
        require "snowflaked/type/snowflake"
        ActiveRecord::Type.register(:snowflake, Snowflaked::Type::Snowflake)
      end
    end

    initializer "snowflaked.extend_adapters", after: "active_record.initialize_database" do
      ActiveSupport.on_load(:active_record) do
        require "snowflaked/adapter_extension"

        adapters = %w[
          PostgreSQLAdapter
          Mysql2Adapter
          TrilogyAdapter
          SQLite3Adapter
        ]

        adapters.each do |adapter_name|
          next unless ActiveRecord::ConnectionAdapters.const_defined?(adapter_name)

          ActiveRecord::ConnectionAdapters.const_get(adapter_name).prepend(
            Snowflaked::AdapterExtension
          )
        end
      end
    end

    initializer "snowflaked.schema_definitions", after: "active_record.initialize_database" do
      ActiveSupport.on_load(:active_record) do
        require "snowflaked/schema_definitions"

        ActiveRecord::ConnectionAdapters::TableDefinition.include(Snowflaked::SchemaDefinitions::TableDefinition)
        ActiveRecord::ConnectionAdapters::Table.include(Snowflaked::SchemaDefinitions::Table)
      end
    end

    initializer "snowflaked.model_extensions", after: "active_record.initialize_database" do
      ActiveSupport.on_load(:active_record) do
        require "snowflaked/model_extensions"
        ActiveRecord::Base.include(Snowflaked::ModelExtensions)
      end
    end
  end
end
