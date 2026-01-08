# frozen_string_literal: true

module Snowflaked
  module Type
    class Snowflake < ActiveRecord::Type::BigInteger
      def type
        :snowflake
      end
    end
  end
end
