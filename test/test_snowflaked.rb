# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

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

    assert_in_delta Time.zone.now, timestamp, 5
  end

  def test_thread_safety_under_contention
    threads = Array.new(50) do
      Thread.new { Array.new(200) { Snowflaked.id } }
    end

    all_ids = threads.flat_map(&:value)

    assert_equal 10_000, all_ids.size
    assert_equal 10_000, all_ids.uniq.size, "Generated duplicate IDs under heavy thread contention"
  end

  def test_parse_components_are_consistent
    ids = Array.new(100) { Snowflaked.id }
    machine_id = Snowflaked.configuration.machine_id_value

    ids.each do |id|
      parsed = Snowflaked.parse(id)

      assert_equal Snowflaked.timestamp_ms(id), parsed[:timestamp_ms]
      assert_equal machine_id, parsed[:machine_id]
      assert_equal Snowflaked.sequence(id), parsed[:sequence]
    end
  end

  def test_fork_safety
    parent_ids        = Array.new(100) { Snowflaked.id }
    parent_machine_id = Snowflaked.machine_id(parent_ids.first)

    child_ids, child_machine_id = fork_and_collect { [Array.new(100) { Snowflaked.id }, Snowflaked.configuration.machine_id_value] }

    assert_not_equal parent_machine_id, child_machine_id, "Child should reinitialize with different machine_id after fork"
    assert_equal 200, (parent_ids + child_ids).uniq.size, "Generated duplicate IDs across forked processes"
  end

  def test_fork_safety_with_background_thread # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
    stop = false
    started = Queue.new
    wait_timeout = 5

    bg_thread = Thread.new do
      Snowflaked.id
      started << true
      Snowflaked.id until stop
    end

    begin
      Timeout.timeout(wait_timeout) { started.pop }

      child_ids, = fork_and_collect do
        require "timeout"
        Timeout.timeout(5) do
          [Array.new(100) { Snowflaked.id }, Snowflaked.configuration.machine_id_value]
        end
      end

      assert_equal 100, child_ids.uniq.size
    ensure
      stop = true
      unless bg_thread.join(wait_timeout)
        bg_thread.kill
        bg_thread.join(1)

        flunk "Background thread did not stop within #{wait_timeout} seconds"
      end
    end
  end

  def test_first_generation_after_fork_is_thread_safe
    child_ids, = fork_and_collect do
      threads = Array.new(20) do
        Thread.new { Array.new(100) { Snowflaked.id } }
      end

      [threads.flat_map(&:value)]
    end

    assert_equal 2000, child_ids.size
    assert_equal 2000, child_ids.uniq.size
  end

  def test_epoch_ms_returns_exact_milliseconds_without_float_rounding
    epoch = Time.at(Rational(1_704_067_200_002, 1000)).utc
    config = Snowflaked::Configuration.new
    config.epoch = epoch

    assert_equal 1_704_067_200_002, config.epoch_ms,
                 "epoch_ms must use exact Rational arithmetic; to_f loses 1ms for sub-millisecond epoch values"
  end

  def test_default_epoch_does_not_overflow_before_2093 # rubocop:disable Naming/VariableNumber
    config = Snowflaked::Configuration.new
    epoch_ms = config.epoch_ms.to_i
    max_snowflake_ms = (2**41) - 1
    overflow_time = Time.at((epoch_ms + max_snowflake_ms) / 1000.0).utc

    assert_operator overflow_time.year, :>=, 2093, "Default epoch causes 41-bit timestamp overflow in #{overflow_time.year}. " \
                                                   "Set a default epoch of at least 2024-01-01 to push overflow to ~2093."
  end

  def test_ids_are_non_negative
    1000.times { assert_operator Snowflaked.id, :>=, 0 }
  end

  def test_machine_id_value_computed_once_per_process
    config = Snowflaked::Configuration.new
    calls = 0

    config.define_singleton_method(:resolve_machine_id) do
      calls += 1
      123
    end

    3.times { config.machine_id_value }

    assert_equal 1, calls, "machine_id_value must memoize and not resolve on every access"
  end

  def test_machine_id_value_refreshes_value_before_pid
    old_pid = Process.pid - 1
    config = configuration_with_stale_machine_id(old_pid)
    pid_seen_while_resolving = nil

    config.define_singleton_method(:resolve_machine_id) do
      pid_seen_while_resolving = instance_variable_get(:@machine_id_value_pid)
      456
    end

    assert_equal 456, config.machine_id_value
    assert_equal old_pid, pid_seen_while_resolving
    assert_equal Process.pid, config.instance_variable_get(:@machine_id_value_pid)
  end

  def test_machine_id_writer_clears_cached_process_value
    config = Snowflaked::Configuration.new
    config.machine_id_value
    config.machine_id = 456

    assert_equal 456, config.machine_id_value
  end

  def test_explicit_out_of_range_machine_id_raises
    config = Snowflaked::Configuration.new

    assert_raises(Snowflaked::ConfigurationError) { config.machine_id = Snowflaked::MAX_MACHINE_ID + 1 }
  end

  def test_non_integer_env_machine_id_raises
    config = Snowflaked::Configuration.new

    ENV["SNOWFLAKED_MACHINE_ID"] = "not-a-number"
    assert_raises(Snowflaked::ConfigurationError) { config.machine_id_value }
  ensure
    ENV.delete("SNOWFLAKED_MACHINE_ID")
  end

  def test_timestamp_falls_back_to_utc_without_time_zone
    id = Snowflaked.id

    Time.use_zone(nil) do
      timestamp = Snowflaked.timestamp(id)

      assert_kind_of Time, timestamp
      assert_predicate timestamp, :utc?
    end
  end

  def test_machine_id_cannot_change_after_configuration_is_sealed
    config = Snowflaked::Configuration.new
    config.machine_id = 123
    config.seal!

    assert_raises(Snowflaked::ConfigurationError) { config.machine_id = 456 }
    assert_equal 123, config.machine_id
  end

  def test_nil_epoch_falls_back_to_unix_epoch
    config = Snowflaked::Configuration.new
    config.epoch = nil

    assert_nil config.epoch
    assert_nil config.epoch_ms
  end

  def test_future_epoch_raises
    config = Snowflaked::Configuration.new

    assert_raises(Snowflaked::ConfigurationError) { config.epoch = Time.now.utc + 3600 }
  end

  def test_epoch_cannot_change_after_configuration_is_sealed
    epoch = Time.utc(2024, 1, 1)
    config = Snowflaked::Configuration.new
    config.epoch = epoch
    config.seal!

    assert_raises(Snowflaked::ConfigurationError) { config.epoch = Time.utc(2025, 1, 1) }
    assert_equal epoch, config.epoch
  end

  private

  def configuration_with_stale_machine_id(old_pid)
    Snowflaked::Configuration.new.tap do |config|
      config.instance_variable_set(:@machine_id_value, 123)
      config.instance_variable_set(:@machine_id_value_pid, old_pid)
    end
  end

  def fork_and_collect(&block)
    IO.pipe do |read_io, write_io|
      pid = fork { write_child_payload(read_io, write_io, block) }
      write_io.close
      parse_child_payload(read_io.read, pid)
    end
  end

  def write_child_payload(read_io, write_io, block)
    read_io.close
    write_io.puts(JSON.dump(block.call))
    exit!(0)
  end

  def parse_child_payload(payload, pid)
    _, status = Process.wait2(pid)

    assert_predicate status, :success?, "forked child exited unsuccessfully"

    JSON.parse(payload)
  end
end
