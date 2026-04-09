# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in snowflaked.gemspec
gemspec

gem "irb"
gem "rake"

gem "minitest"
gem "rake-compiler"

gem "activerecord", ">= 7.0"
gem "pg"
gem "railties", ">= 7.0"

gem "rubocop", require: false
gem "rubocop-md", require: false
gem "rubocop-minitest", require: false
gem "rubocop-performance", require: false
gem "rubocop-rake", require: false

gem "appraisal", group: %i[development test]

if RUBY_VERSION < "3.3"
  gem "parallel", "< 2"
else
  gem "parallel", "~> 2"
end

gem "debug"
