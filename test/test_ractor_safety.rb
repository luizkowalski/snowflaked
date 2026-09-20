# frozen_string_literal: true

require_relative "test_helper"

class TestRactorSafety < ActiveSupport::TestCase
  include ForkHelpers

  def test_generates_unique_ids_across_ractors_after_main_initialization
    Snowflaked.id

    ractors = Array.new(4) { Ractor.new { Array.new(250) { Snowflaked.id } } }
    all_ids = ractors.flat_map { |ractor| Ractor.select(ractor).last }

    assert_equal 1000, all_ids.size
    assert_equal 1000, all_ids.uniq.size, "Generated duplicate IDs across Ractors"
  end

  def test_reads_id_parts_inside_a_ractor
    id = Snowflaked.id

    ractor = Ractor.new(id) { |value| Snowflaked.parse(value) }
    _, parsed = Ractor.select(ractor)

    assert_equal Snowflaked.parse(id), parsed
  end

  def test_raises_when_the_first_id_after_fork_comes_from_a_non_main_ractor
    Snowflaked.id

    error, = fork_and_collect do
      ractor = Ractor.new do
        Snowflaked.id
      rescue Ractor::IsolationError => e
        e.class.name
      end

      [Ractor.select(ractor).last]
    end

    assert_equal "Ractor::IsolationError", error
  end
end
