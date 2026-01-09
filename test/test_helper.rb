# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require_relative "dummy/config/environment"

require "minitest/autorun"

ActiveRecord::MigrationContext.new("test/dummy/db/migrate").migrate

class User < ActiveRecord::Base
end
