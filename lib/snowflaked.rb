# frozen_string_literal: true

require_relative "snowflaked/version"

# Load precompiled extension for the current Ruby version
begin
  ruby_version = /(\d+\.\d+)/.match(RUBY_VERSION)
  require "snowflaked/#{ruby_version}/snowflaked"
rescue LoadError
  require "snowflaked/snowflaked"
end

require "socket"

require_relative "snowflaked/railtie" if defined?(Rails::Railtie)

module Snowflaked
  MAX_MACHINE_ID = 1023
  DEFAULT_EPOCH = Time.utc(2024, 1, 1).freeze

  class Error < StandardError; end
  class ConfigurationError < Error; end

  class Configuration
    attr_reader :machine_id, :epoch

    def initialize
      @machine_id = nil
      @epoch      = DEFAULT_EPOCH
      @sealed     = false
    end

    def machine_id=(value)
      raise_if_sealed!(:machine_id)

      @machine_id           = value.nil? ? nil : checked_machine_id(value)
      @machine_id_value     = nil
      @machine_id_value_pid = nil
    end

    def epoch=(value)
      raise_if_sealed!(:epoch)

      @epoch    = value
      @epoch_ms = nil
    end

    def seal!
      @sealed = true
    end

    def machine_id_value
      if @machine_id_value_pid != Process.pid
        @machine_id_value     = resolve_machine_id
        @machine_id_value_pid = Process.pid
      end

      @machine_id_value
    end

    def epoch_ms
      return nil unless @epoch

      @epoch_ms ||= (@epoch.to_r * 1000).to_i
    end

    private

    # Resolution order: explicit config, then env vars, then an auto fallback.
    # Explicit and env values are range-checked; the fallback is always valid.
    def resolve_machine_id
      return @machine_id unless @machine_id.nil?

      env = ENV["SNOWFLAKED_MACHINE_ID"] || ENV.fetch("MACHINE_ID", nil)
      return checked_machine_id(env) if env

      # Unique-enough per process without coordination: varies by host and by
      # pid, so forked workers each get a different id. % keeps it in range.
      (Socket.gethostname.hash ^ Process.pid) % (MAX_MACHINE_ID + 1)
    end

    # Coerce to Integer and ensure it fits in 0..MAX_MACHINE_ID, else raise.
    def checked_machine_id(value)
      id = Integer(value, exception: false)
      return id if id&.between?(0, MAX_MACHINE_ID)

      raise ConfigurationError, "machine_id must be an integer between 0 and #{MAX_MACHINE_ID}, got #{value.inspect}"
    end

    def raise_if_sealed!(attribute)
      return unless @sealed

      raise ConfigurationError, "#{attribute} cannot be changed after Snowflaked has been configured"
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
      ensure_initialized!
      seconds, milliseconds = Native.timestamp_ms(id).divmod(1000)

      if defined?(Time.zone) && Time.zone
        Time.zone.at(seconds, milliseconds * 1000, :usec)
      else
        Time.at(seconds, milliseconds * 1000, :usec).utc
      end
    end

    def machine_id(id) # rubocop:disable Rails/Delegate
      Native.machine_id(id)
    end

    def timestamp_ms(id)
      ensure_initialized!
      Native.timestamp_ms(id)
    end

    def sequence(id) # rubocop:disable Rails/Delegate
      Native.sequence(id)
    end

    private

    def ensure_initialized!
      return if @native_initialized_pid == Process.pid

      config = configuration
      config.seal!

      Native.init_generator(config.machine_id_value, config.epoch_ms)
      @native_initialized_pid = Process.pid
    end
  end
end
