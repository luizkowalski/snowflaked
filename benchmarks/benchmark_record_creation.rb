# frozen_string_literal: true

RubyVM::YJIT.enable if defined?(RubyVM::YJIT)

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails", "~> 8.1"
  gem "pg"
  gem "snowflaked", path: ".."
  gem "benchmark-ips"
end

require "active_record"
require "benchmark/ips"
require "snowflaked"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: "snowflaked_benchmark",
  host: "localhost"
)

require "snowflaked/schema_definitions"
require "snowflaked/model_extensions"
ActiveRecord::Base.include(Snowflaked::ModelExtensions)

ActiveRecord::Schema.define do
  drop_table :posts_with_snowflake_id, if_exists: true
  drop_table :posts_with_snowflake_disabled, if_exists: true

  create_table :posts_with_snowflake_id, id: false do |t|
    t.bigint :id, primary_key: true
    t.string :title
  end

  create_table :posts_with_snowflake_disabled, id: false do |t|
    t.bigint :id, primary_key: true
    t.string :title
  end
end

class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end

class PostWithSnowflakeId < ApplicationRecord
  self.table_name = "posts_with_snowflake_id"
end

class PostWithSnowflakeDisabled < ApplicationRecord
  self.table_name = "posts_with_snowflake_disabled"
  snowflake_id id: false
end

puts "Ruby version: #{RUBY_VERSION}"
puts "Rails version: #{Rails.version}"
puts "Snowflaked version: #{Snowflaked::VERSION}"
puts "YJIT: #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 'enabled' : 'disabled'}"
puts "\n"

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report("Snowflake ID") do
    PostWithSnowflakeId.create!(title: "Test Post")
  end

  x.report("Database-backed ID ") do
    PostWithSnowflakeDisabled.create!(title: "Test Post")
  end

  x.compare!
end

PostWithSnowflakeId.delete_all
PostWithSnowflakeDisabled.delete_all
