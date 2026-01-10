# frozen_string_literal: true

require_relative "test_helper"

class TestSnowflaked < ActiveSupport::TestCase
  def test_generates_unique_ids
    ids = Array.new(1000) { Snowflaked.id }

    assert_equal 1000, ids.uniq.size
  end

  def test_generates_integer_ids
    id = Snowflaked.id

    assert_kind_of Integer, id
  end

  def test_parse_returns_hash_with_components
    id = Snowflaked.id
    parsed = Snowflaked.parse(id)

    assert_kind_of Hash, parsed
    assert parsed.key?(:timestamp_ms)
    assert parsed.key?(:machine_id)
    assert parsed.key?(:sequence)
  end

  def test_timestamp_returns_time_object
    id = Snowflaked.id
    timestamp = Snowflaked.timestamp(id)

    assert_kind_of Time, timestamp
  end

  def test_timestamp_ms_returns_integer
    id = Snowflaked.id
    timestamp_ms = Snowflaked.timestamp_ms(id)

    assert_kind_of Integer, timestamp_ms
  end

  def test_machine_id_returns_integer
    id = Snowflaked.id
    machine_id = Snowflaked.machine_id(id)

    assert_kind_of Integer, machine_id
    assert_operator machine_id, :>=, 0
    assert_operator machine_id, :<, 1024
  end

  def test_sequence_returns_integer
    id = Snowflaked.id
    sequence = Snowflaked.sequence(id)

    assert_kind_of Integer, sequence
  end

  def test_ids_are_monotonically_increasing
    id1 = Snowflaked.id
    id2 = Snowflaked.id
    id3 = Snowflaked.id

    assert_operator id1, :<, id2
    assert_operator id2, :<, id3
  end

  def test_machine_id_matches_configuration
    machine_id = Snowflaked.configuration.machine_id_value
    id = Snowflaked.id
    parsed_machine_id = Snowflaked.machine_id(id)

    assert_equal machine_id, parsed_machine_id
  end

  def test_thread_safety
    threads = Array.new(10) do
      Thread.new { Array.new(100) { Snowflaked.id } } # -- Intentional
    end

    all_ids = threads.flat_map(&:value)

    assert_equal 1000, all_ids.size
    assert_equal 1000, all_ids.uniq.size, "Generated duplicate IDs across threads"
  end

  def test_timestamp_preserves_millisecond_precision
    id = Snowflaked.id
    time_ms = Snowflaked.timestamp_ms(id)
    timestamp = Snowflaked.timestamp(id)

    reconstructed_ms = (timestamp.to_f * 1000).round

    assert_in_delta time_ms, reconstructed_ms, 1
  end

  def test_custom_epoch_offsets_correctly
    expected_epoch = Time.utc(2023, 1, 1)

    assert_equal expected_epoch, Snowflaked.configuration.epoch, "Custom epoch was not loaded from initializer"

    id = Snowflaked.id
    timestamp = Snowflaked.timestamp(id)

    # ensure the generated timestamp is current (within 5 seconds),
    # proving that the custom epoch offset was handled correctly by both Generator and Parser.
    assert_in_delta Time.now, timestamp, 5
  end
end
