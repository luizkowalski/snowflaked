# frozen_string_literal: true

require_relative "boot"

require "active_record/railtie"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
  end
end
