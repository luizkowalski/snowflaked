# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
require "rails/test_help"
Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

ActiveRecord::Schema.verbose = false
load Rails.root.join("db/schema.rb").to_s # Load the schema for the test database
