# frozen_string_literal: true

module Snowflaked
  module Generator
    MAX_SIGNED_ID   = (1 << 63) - 1
    MAX_UNSIGNED_ID = (1 << 64) - 1
    MACHINE_MASK    = 0x3ff
    SEQUENCE_MASK   = 0xfff
    INITIALIZATION_LOCK = Mutex.new

    class State
      def initialize(machine_id, epoch_ms)
        @machine_id = machine_id
        @epoch_ms = epoch_ms
        @timestamp = -1
        @sequence = 0
      end

      def generate
        timestamp = current_timestamp
        return if timestamp < @timestamp

        sequence = timestamp == @timestamp ? @sequence + 1 : 0
        timestamp = next_timestamp if sequence > SEQUENCE_MASK
        return unless timestamp

        @sequence = timestamp > @timestamp ? 0 : sequence
        @timestamp = timestamp
        compose(timestamp, @sequence)
      end

      private

      def next_timestamp
        loop do
          timestamp = current_timestamp
          return if timestamp < @timestamp

          return timestamp if timestamp > @timestamp
        end
      end

      def current_timestamp
        Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) - @epoch_ms
      end

      def compose(timestamp, sequence)
        ((timestamp << 22) & MAX_SIGNED_ID) | (@machine_id << 12) | sequence
      end
    end

    class << self
      def init(machine_id, epoch_ms)
        epoch_ms = checked_epoch(epoch_ms)

        INITIALIZATION_LOCK.synchronize do
          return false if initialized?

          @epoch_ms = epoch_ms
          @server = start_server(machine_id)
          @pid = Process.pid
          true
        end
      end

      def generate
        result = response

        return result if result

        raise "Snowflaked: system clock moved backwards; cannot generate a monotonic ID"
      end

      def initialized?
        @pid == Process.pid
      end

      def parse(id)
        value = checked_id(id)

        {
          timestamp_ms: timestamp_ms_from_checked_id(value),
          machine_id: machine_id_from_checked_id(value),
          sequence: sequence_from_checked_id(value),
        }
      end

      def timestamp_ms(id)
        timestamp_ms_from_checked_id(checked_id(id))
      end

      def machine_id(id)
        machine_id_from_checked_id(checked_id(id))
      end

      def sequence(id)
        sequence_from_checked_id(checked_id(id))
      end

      private

      def start_server(machine_id)
        Ractor.new(machine_id, @epoch_ms) do |id, epoch|
          state = State.new(id, epoch)

          loop do
            reply = Ractor.receive
            reply.send(state.generate)
          end
        end
      end

      def response
        return port_response if defined?(Ractor::Port)

        legacy_response
      end

      def port_response
        reply = Ractor::Port.new
        @server.send(reply)
        reply.receive
      end

      def legacy_response
        lock = Ractor.store_if_absent(:snowflaked_generator_reply_lock) { Mutex.new }
        lock.synchronize do
          reply = legacy_reply
          @server.send(reply)
          reply.take
        end
      end

      def legacy_reply
        cache = Ractor.current[:snowflaked_generator_reply]
        return cache.last if cache&.first == Process.pid

        reply = Ractor.new do
          loop { Ractor.yield(Ractor.receive) }
        end
        Ractor.current[:snowflaked_generator_reply] = [Process.pid, reply]
        reply
      end

      def checked_epoch(epoch_ms)
        value = epoch_ms.nil? ? 0 : Integer.try_convert(epoch_ms)
        raise TypeError, "no implicit conversion of #{epoch_ms.class} into Integer" unless value.is_a?(Integer)
        raise RangeError, "epoch milliseconds are outside the unsigned 64-bit range" unless value.between?(0, MAX_UNSIGNED_ID)

        value
      end

      def checked_id(id)
        value = Integer.try_convert(id)
        raise TypeError, "no implicit conversion of #{id.class} into Integer" unless value.is_a?(Integer)
        raise RangeError, "Snowflake ID is outside the unsigned 64-bit range" unless value.between?(0, MAX_UNSIGNED_ID)

        value
      end

      def timestamp_ms_from_checked_id(id)
        [(id >> 22) + (@epoch_ms || 0), MAX_UNSIGNED_ID].min
      end

      def machine_id_from_checked_id(id)
        (id >> 12) & MACHINE_MASK
      end

      def sequence_from_checked_id(id)
        id & SEQUENCE_MASK
      end
    end
  end
end
