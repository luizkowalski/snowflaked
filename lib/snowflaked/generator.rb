# frozen_string_literal: true

module Snowflaked
  module Generator
    MAX_SIGNED_ID   = (1 << 63) - 1
    MAX_UNSIGNED_ID = (1 << 64) - 1
    MACHINE_MASK    = 0x3ff
    SEQUENCE_MASK   = 0xfff

    # The 12 sequence bits are split: a high slot owned by one Ractor, and a
    # low counter that Ractor advances alone. Two Ractors therefore never
    # compose the same ID, so nothing has to be coordinated per ID.
    #
    # SLOT_BITS trades Ractor count against per-Ractor rate, and nothing else:
    # 2 bits gives 4 Ractors at 1,024 IDs/ms each, 3 gives 8 at 512, 4 gives
    # 16 at 256. Any of them costs about 540ns per ID. Set it with the
    # SNOWFLAKED_SLOT_BITS environment variable before boot; 0 gives a
    # process that never generates in a non-main Ractor the full 4,096/ms.
    SLOT_BITS = Integer(ENV.fetch("SNOWFLAKED_SLOT_BITS", "3")).tap do |bits|
      raise ArgumentError, "SNOWFLAKED_SLOT_BITS must be between 0 and 10, got #{bits}" unless bits.between?(0, 10)
    end
    SLOT_COUNT    = 1 << SLOT_BITS
    SEQUENCE_BITS = 12 - SLOT_BITS
    MAX_SEQUENCE  = (1 << SEQUENCE_BITS) - 1

    class State
      def initialize(machine_id, epoch_ms, slot)
        @machine_id = machine_id
        @epoch_ms = epoch_ms
        @slot = slot << SEQUENCE_BITS
        # This slot may have belonged to a Ractor that died moments ago (or,
        # after a fork, to the parent process). Its counter is unknown, so
        # refuse to issue anything in the construction millisecond: the first
        # ID waits for the next one, which no previous holder can have used.
        @timestamp = current_timestamp
        @sequence = MAX_SEQUENCE
      end

      def generate
        timestamp = current_timestamp
        return if timestamp < @timestamp

        sequence = timestamp == @timestamp ? @sequence + 1 : 0
        timestamp = next_timestamp if sequence > MAX_SEQUENCE
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
        ((timestamp << 22) & MAX_SIGNED_ID) | (@machine_id << 12) | @slot | sequence
      end
    end

    # Runs inside the slot server Ractor. Lends every other Ractor a slot for
    # as long as it lives, and takes the slot back when it exits. The one
    # blocking select serves requests and exits alike, so the server costs
    # nothing while it waits.
    class SlotPool
      def initialize(count)
        @free = (1...count).to_a
        @leases = {} # a monitor port per live lease => the slot it holds
      end

      def run
        loop do
          port, message = Ractor.select(Ractor.current.default_port, *@leases.keys)
          released = @leases.delete(port)

          released ? @free << released : lease(*message)
        end
      end

      private

      def lease(requester, reply)
        slot = @free.shift

        if slot
          deaths = Ractor::Port.new
          requester.monitor(deaths)
          @leases[deaths] = slot
        end

        reply.send(slot)
      end
    end

    class << self
      def init(machine_id, epoch_ms)
        epoch_ms = checked_epoch(epoch_ms)

        Ractor.store_if_absent(:snowflaked_init_lock) { Mutex.new }.synchronize do
          return false if initialized?

          # Written once, on the main Ractor, before any other Ractor starts.
          # Every value is shareable, so other Ractors can read them.
          @machine_id = machine_id # audition:disable class-level-state
          @epoch_ms = epoch_ms # audition:disable class-level-state
          @slots = start_slot_server # audition:disable class-level-state
          @pid = Process.pid # audition:disable class-level-state
          true
        end
      end

      def generate
        result = state_lock.synchronize { local_state.generate }

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

      # Threads share their Ractor's State, so they still serialize; Ractors
      # do not, because each one holds a State on a slot of its own.
      def state_lock
        Ractor.store_if_absent(:snowflaked_state_lock) { Mutex.new }
      end

      def local_state
        cache = Ractor.current[:snowflaked_state]
        return cache.last if cache&.first == Process.pid

        state = State.new(@machine_id, @epoch_ms, claim_slot)
        Ractor.current[:snowflaked_state] = [Process.pid, state]
        state
      end

      # The main Ractor always owns slot 0, so a program that never starts a
      # Ractor never talks to the slot server at all.
      def claim_slot
        return 0 if Ractor.main?

        raise Snowflaked::Error, "Snowflaked: generating IDs outside the main Ractor needs Ruby 4.0 or later" unless @slots

        slot = request_slot
        return slot if slot

        raise Snowflaked::Error,
              "Snowflaked: #{SLOT_COUNT} Ractors already hold a sequence slot; " \
              "set the SNOWFLAKED_SLOT_BITS environment variable to trade per-Ractor throughput for more Ractors"
      end

      def request_slot
        port = Ractor::Port.new
        @slots.monitor(port) # a dead server delivers :exited here instead of leaving us blocked forever
        @slots.send([Ractor.current, port])
        slot = port.receive
        @slots.unmonitor(port)
        raise Snowflaked::Error, "Snowflaked: the slot server Ractor died; cannot claim a sequence slot" if slot == :exited

        slot
      rescue Ractor::ClosedError
        raise Snowflaked::Error, "Snowflaked: the slot server Ractor died; cannot claim a sequence slot"
      end

      # The server is an implementation detail, so its Ractor.new should not
      # put "Ractor API is experimental" in every Rails boot log. The first
      # Ractor the application itself starts still warns.
      def start_slot_server
        return unless defined?(Ractor::Port)

        previous = Warning[:experimental]
        Warning[:experimental] = false
        Ractor.new(SLOT_COUNT) { |count| SlotPool.new(count).run }
      ensure
        Warning[:experimental] = previous unless previous.nil?
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
