# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require_relative "dummy/config/environment"

require "minitest/autorun"

ActiveRecord::Schema.define do
  create_table :users, id: :snowflake, force: true do |t|
    t.string :name
    t.snowflake :external_id
  end
end

class User < ActiveRecord::Base
  snowflake_id :id, :external_id
end
