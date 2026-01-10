# frozen_string_literal: true

module Snowflaked
  module ModelExtensions
    extend ActiveSupport::Concern

    included do
      class_attribute :_snowflake_attributes, instance_writer: false, default: [:id]
      before_validation :_generate_snowflake_ids, on: :create
    end

    class_methods do
      def snowflake_id(*attributes, id: true)
        attrs = attributes.map(&:to_sym)
        attrs |= [:id] if id
        self._snowflake_attributes = attrs
      end

      def _snowflake_columns_from_comments
        return @_snowflake_columns_from_comments if defined?(@_snowflake_columns_from_comments)

        @_snowflake_columns_from_comments = if table_exists?
          columns.filter_map { |col| col.name.to_sym if col.comment == Snowflaked::SchemaDefinitions::COMMENT }
        else
          []
        end
      end
    end

    private

    def _generate_snowflake_ids
      attributes_to_generate = self.class._snowflake_attributes | self.class._snowflake_columns_from_comments

      attributes_to_generate.each do |attribute|
        next if self[attribute].present?

        self[attribute] = Snowflaked.id
      end
    end
  end
end
