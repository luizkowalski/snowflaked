# frozen_string_literal: true

require_relative "test_helper"

class TestGenerator < ActiveSupport::TestCase
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
    times = ([2_000] * 4_097) + [2_001]
    state = state_with_timestamps(*times)

    ids = Array.new(4_097) { state.generate }

    assert_equal 4_095, ids[-2] & 0xfff
    assert_equal 0, ids[-1] & 0xfff
    assert_equal 1_001, ids[-1] >> 22
  end

  def test_recovers_after_clock_rolls_back_while_waiting_for_sequence_rollover
    times = ([2_000] * 4_097) + [1_999, 2_001]
    state = state_with_timestamps(*times)
    4_096.times { state.generate }

    assert_nil state.generate
    assert_equal 1_001, state.generate >> 22
  end

  def test_preserves_rollover_after_rollback_until_a_later_timestamp
    times = ([2_000] * 4_097) + [1_999, 2_000, 2_001]
    state = state_with_timestamps(*times)
    ids = Array.new(4_096) { state.generate }

    assert_nil state.generate

    rollover_id = state.generate

    assert_equal 4_097, (ids + [rollover_id]).uniq.size
    assert_equal 0, rollover_id & 0xfff
    assert_equal 1_001, rollover_id >> 22
  end

  def test_rejects_epoch_milliseconds_outside_unsigned_64_bit_range
    [-1, Snowflaked::Generator::MAX_UNSIGNED_ID + 1].each do |epoch_ms|
      assert_raises(RangeError) { Snowflaked::Generator.init(42, epoch_ms) }
    end
  end

  def test_nil_epoch_uses_unix_epoch
    assert_predicate generator_init_status(nil, expected_epoch_ms: 0), :success?
  end

  def test_returns_nil_when_clock_moves_backwards
    state = state_with_timestamps(2_000, 1_999, 2_001)
    state.generate

    assert_nil state.generate
    assert_kind_of Integer, state.generate
  end

  private

  def state_with_timestamps(*timestamps)
    timestamps = timestamps.each
    Snowflaked::Generator::State.new(42, 1_000).tap do |state|
      state.define_singleton_method(:current_timestamp) { timestamps.next - @epoch_ms }
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
