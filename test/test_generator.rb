# frozen_string_literal: true

require_relative "test_helper"

class TestGenerator < ActiveSupport::TestCase
  SLOTS    = Snowflaked::Generator::SLOT_COUNT
  SEQ_BITS = Snowflaked::Generator::SEQUENCE_BITS
  PER_MS   = Snowflaked::Generator::MAX_SEQUENCE + 1

  def test_parses_expected_components
    id = 862_026_798_833_074_178

    assert_equal 1_878_054_404_525, Snowflaked::Generator.timestamp_ms(id)
    assert_equal 256, Snowflaked::Generator.machine_id(id)
    assert_equal 2, Snowflaked::Generator.sequence(id)
    assert_equal({ timestamp_ms: 1_878_054_404_525, machine_id: 256, sequence: 2 }, Snowflaked::Generator.parse(id))
  end

  def test_rejects_invalid_ids_before_parsing
    assert_raises(TypeError) { Snowflaked::Generator.timestamp_ms("1") }
    assert_raises(RangeError) { Snowflaked::Generator.machine_id(-1) }
    assert_raises(RangeError) { Snowflaked::Generator.sequence(Snowflaked::Generator::MAX_UNSIGNED_ID + 1) }
  end

  def test_coerces_integer_like_ids
    id = Object.new
    calls = 0
    id.define_singleton_method(:to_int) do
      calls += 1
      4_194_304
    end

    assert_equal({ timestamp_ms: 1_672_531_200_001, machine_id: 0, sequence: 0 }, Snowflaked::Generator.parse(id))
    assert_equal 1, calls
    assert_equal 1_672_531_200_001, Snowflaked::Generator.timestamp_ms(4_194_304.9)
    assert_equal 3, Snowflaked::Generator.sequence(Rational(7, 2))
  end

  def test_saturates_timestamp_at_the_unsigned_64_bit_limit
    epoch_ms = Snowflaked::Generator.instance_variable_get(:@epoch_ms)
    Snowflaked::Generator.instance_variable_set(:@epoch_ms, Snowflaked::Generator::MAX_UNSIGNED_ID)

    assert_equal Snowflaked::Generator::MAX_UNSIGNED_ID, Snowflaked::Generator.timestamp_ms(4_194_304)
  ensure
    Snowflaked::Generator.instance_variable_set(:@epoch_ms, epoch_ms)
  end

  def test_generates_expected_components
    state = state_with_timestamps(2_000)

    id = state.generate

    assert_equal 1_000, id >> 22
    assert_equal 42, (id >> 12) & 0x3ff
    assert_equal 0, id & 0xfff
  end

  def test_starts_at_sequence_zero_at_the_epoch
    state = state_with_timestamps(1_000)

    assert_equal 0, state.generate & 0xfff
  end

  def test_increments_sequence_in_the_same_millisecond
    state = state_with_timestamps(2_000, 2_000)

    first = state.generate
    second = state.generate

    assert_equal 0, first & 0xfff
    assert_equal 1, second & 0xfff
  end

  def test_waits_for_next_millisecond_after_sequence_exhaustion
    state = exhausted_state(2_001)

    ids = Array.new(PER_MS + 1) { state.generate }

    assert_equal PER_MS - 1, ids[-2] & 0xfff
    assert_equal 0, ids[-1] & 0xfff
    assert_equal 1_001, ids[-1] >> 22
  end

  def test_recovers_after_clock_rolls_back_while_waiting_for_sequence_rollover
    state = exhausted_state(1_999, 2_001)
    PER_MS.times { state.generate }

    assert_nil state.generate
    assert_equal 1_001, state.generate >> 22
  end

  def test_preserves_rollover_after_rollback_until_a_later_timestamp
    state = exhausted_state(1_999, 2_000, 2_001)
    ids = Array.new(PER_MS) { state.generate }

    assert_nil state.generate

    rollover = state.generate

    assert_equal PER_MS + 1, (ids << rollover).uniq.size
    assert_equal 0, rollover & 0xfff
    assert_equal 1_001, rollover >> 22
  end

  def test_rejects_epoch_milliseconds_outside_unsigned_64_bit_range
    [-1, Snowflaked::Generator::MAX_UNSIGNED_ID + 1].each do |epoch_ms|
      assert_raises(RangeError) { Snowflaked::Generator.init(42, epoch_ms) }
    end
  end

  def test_nil_epoch_uses_unix_epoch
    assert_predicate generator_init_status(nil, expected_epoch_ms: 0), :success?
  end

  def test_slots_occupy_the_high_sequence_bits_and_never_collide
    states = Array.new(SLOTS) { |slot| state_with_timestamps(2_000, 2_000, slot: slot) }
    ids = states.flat_map { |state| [state.generate, state.generate] }

    assert_equal ids.size, ids.uniq.size
    assert_equal (0...SLOTS).to_a, ids.map { |id| (id & 0xfff) >> SEQ_BITS }.uniq.sort
  end

  def test_first_id_waits_out_the_construction_millisecond
    state = Snowflaked::Generator::State.new(42, 1_000, 0)
    floor = state.instance_variable_get(:@timestamp)
    clock = [floor, floor, floor + 1].each
    state.define_singleton_method(:current_timestamp) { clock.next }

    id = state.generate

    assert_equal floor + 1, id >> 22, "A fresh State must not issue IDs in the millisecond it claimed its slot"
    assert_equal 0, id & 0xfff & Snowflaked::Generator::MAX_SEQUENCE
  end

  def test_returns_nil_when_clock_moves_backwards
    state = state_with_timestamps(2_000, 1_999, 2_001)
    state.generate

    assert_nil state.generate
    assert_kind_of Integer, state.generate
  end

  private

  # A state whose clock stalls just long enough to exhaust one millisecond.
  def exhausted_state(*after)
    state_with_timestamps(*([2_000] * (PER_MS + 1)), *after)
  end

  # Rewinds the construction-millisecond floor so each test drives the clock
  # from a blank state; the floor itself is covered by its own test above.
  def state_with_timestamps(*timestamps, slot: 0)
    timestamps = timestamps.each
    Snowflaked::Generator::State.new(42, 1_000, slot).tap do |state|
      state.define_singleton_method(:current_timestamp) { timestamps.next - @epoch_ms }
      state.instance_variable_set(:@timestamp, -1)
      state.instance_variable_set(:@sequence, 0)
    end
  end

  def generator_init_status(epoch_ms, expected_epoch_ms: nil)
    pid = fork do
      Snowflaked::Generator.init(42, epoch_ms)
      exit!(expected_epoch_ms == Snowflaked::Generator.instance_variable_get(:@epoch_ms) ? 0 : 1) if expected_epoch_ms

      exit!(1)
    end

    Process.wait2(pid).last
  end
end
