# frozen_string_literal: true

module Snowflaked
  module ModelExtensions
    extend ActiveSupport::Concern

    included do
      _init_snowflake_attributes
      before_create :_generate_snowflake_ids
    end

    class_methods do
      def inherited(subclass)
        super
        subclass._init_snowflake_attributes(_snowflake_attributes)
      end

      def _init_snowflake_attributes(attrs = [:id].freeze)
        @_snowflake_attributes = attrs
      end

      def _snowflake_attributes
        @_snowflake_attributes
      end

      def snowflake_id(*attributes, id: true)
        attrs = attributes.map(&:to_sym)
        attrs |= [:id] if id
        @_snowflake_attributes = attrs.freeze
        @_snowflake_attributes_with_columns = nil
      end

      def _snowflake_columns_from_comments
        return @_snowflake_columns_from_comments if defined?(@_snowflake_columns_from_comments)

        return [] unless table_exists?

        @_snowflake_columns_from_comments = columns.filter_map { |col| col.name.to_sym if col.comment == Snowflaked::SchemaDefinitions::COMMENT }
      end

      def _snowflake_attributes_with_columns
        return _snowflake_attributes unless table_exists?

        @_snowflake_attributes_with_columns ||= (_snowflake_attributes | _snowflake_columns_from_comments)
      end
    end

    private

    def _generate_snowflake_ids
      attributes = self.class._snowflake_attributes_with_columns
      return if attributes.empty?

      attributes.each do |attribute|
        next if self[attribute].present?

        self[attribute] = Snowflaked.id
      end
    end
  end
end
