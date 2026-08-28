# frozen_string_literal: true

require_relative "snowflaked/version"
require_relative "snowflaked/generator"

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

      @epoch    = checked_epoch(value)
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

      # String#hash is seeded per process, so this is effectively a random
      # value in 0..MAX_MACHINE_ID per process. Forked workers inherit the
      # seed but differ by pid. % keeps it in range.
      (Socket.gethostname.hash ^ Process.pid) % (MAX_MACHINE_ID + 1)
    end

    # Ensure the epoch is nil (Unix epoch) or a time-like value not in the
    # future, else raise.
    def checked_epoch(value)
      return value if value.nil? || (value.respond_to?(:to_r) && value.to_r <= Time.now.utc.to_r)

      raise ConfigurationError, "epoch must be a time in the past, got #{value.inspect}"
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
    # Call .configure, or generate the first ID, on the main Ractor.
    # Do this before you start any other Ractor. Each Ractor then owns a
    # sequence slot and generates IDs without any cross-Ractor messages.
    # The Configuration object must stay mutable. You can set machine_id
    # and epoch. The code also sets a new machine_id after each fork.
    # For this reason, audition cannot show that this object is safe to
    # share between Ractors.
    def configuration
      @configuration ||= Configuration.new # audition:disable class-level-state
    end

    def configure
      yield(configuration) if block_given?

      ensure_initialized!
      configuration
    end

    def id
      ensure_initialized!
      Generator.generate
    end

    def parse(id)
      ensure_initialized!
      Generator.parse(id)
    end

    def timestamp(id)
      ensure_initialized!
      seconds, milliseconds = Generator.timestamp_ms(id).divmod(1000)

      if defined?(Time.zone) && Time.zone
        Time.zone.at(seconds, milliseconds * 1000, :usec)
      else
        Time.at(seconds, milliseconds * 1000, :usec).utc
      end
    end

    def machine_id(id) # rubocop:disable Rails/Delegate
      Generator.machine_id(id)
    end

    def timestamp_ms(id)
      ensure_initialized!
      Generator.timestamp_ms(id)
    end

    def sequence(id) # rubocop:disable Rails/Delegate
      Generator.sequence(id)
    end

    private

    def ensure_initialized!
      return if Generator.initialized?

      raise Error, "Snowflaked must be initialized on the main Ractor: call Snowflaked.configure, or generate one ID, before you start any Ractor" unless Ractor.main?

      config = configuration
      config.seal!

      Generator.init(config.machine_id_value, config.epoch_ms)
    end
  end
end
