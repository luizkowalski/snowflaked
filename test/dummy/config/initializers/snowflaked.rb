# frozen_string_literal: true

Snowflaked.configure do |config|
  # Set a custom epoch to verify correct offset calculation
  config.epoch = Time.utc(2023, 1, 1)
end
