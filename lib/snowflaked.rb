# frozen_string_literal: true

require_relative "snowflaked/version"
require_relative "snowflaked/snowflaked"
require "socket"

require_relative "snowflaked/railtie" if defined?(Rails::Railtie)

module Snowflaked
  MAX_MACHINE_ID = 1023

  class Error < StandardError; end
  class ConfigurationError < Error; end

  class Configuration
    attr_accessor :machine_id, :epoch

    def initialize
      @machine_id = nil
      @epoch      = nil
    end

    def machine_id_value
      id = @machine_id || default_machine_id
      id % (MAX_MACHINE_ID + 1)
    end

    def epoch_ms
      return nil unless @epoch

      (@epoch.to_f * 1000).to_i
    end

    private

    def default_machine_id
      env_machine_id || hostname_pid_hash
    end

    def env_machine_id
      id = ENV["SNOWFLAKED_MACHINE_ID"] || ENV.fetch("MACHINE_ID", nil)
      id&.to_i
    end

    def hostname_pid_hash
      (Socket.gethostname.hash ^ Process.pid) % (MAX_MACHINE_ID + 1)
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?

      ensure_initialized!
      configuration
    end

    def id
      ensure_initialized!
      Native.generate
    end

    def parse(id)
      ensure_initialized!
      Native.parse(id)
    end

    def timestamp(id)
      time_ms = Native.timestamp_ms(id)
      Time.at(time_ms / 1000, (time_ms % 1000) * 1000, :usec)
    end

    def machine_id(id)
      ensure_initialized!
      Native.machine_id(id)
    end

    def timestamp_ms(id)
      Native.timestamp_ms(id)
    end

    def sequence(id)
      Native.sequence(id)
    end

    private

    def ensure_initialized!
      return if Native.initialized?

      config = configuration
      Native.init_generator(config.machine_id_value, config.epoch_ms)
    end
  end
end
