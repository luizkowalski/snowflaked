# frozen_string_literal: true

require_relative "test_helper"

class TestRailsIntegration < Minitest::Test
  def setup
    User.delete_all
  end

  def test_creates_table_with_snowflake_primary_key
    column = User.columns_hash["id"]

    assert_equal :integer, column.type
  end

  def test_creates_snowflake_column
    column = User.columns_hash["external_id"]

    assert_equal :integer, column.type
  end

  def test_generates_snowflake_id_on_create
    user = User.create!(name: "Test")

    assert_predicate user.id, :present?
    assert_predicate user.id, :positive?
  end

  def test_generates_external_id_on_create
    user = User.create!(name: "Test")

    assert_predicate user.external_id, :present?
    assert_predicate user.external_id, :positive?
  end

  def test_does_not_overwrite_existing_id
    existing_id = 12_345
    user = User.create!(name: "Test", external_id: existing_id)

    assert_equal existing_id, user.external_id
  end

  def test_generator_recognizes_snowflake_type
    require "rails/generators/generated_attribute"

    assert ActiveRecord::Base.connection.valid_type?(:snowflake), "snowflake should be a valid generator type"
  end

  def test_adapter_class_recognizes_snowflake_type
    assert ActiveRecord::Base.connection.valid_type?(:snowflake), "adapter class should recognize snowflake type"
  end
end
