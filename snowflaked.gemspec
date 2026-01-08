# frozen_string_literal: true

require_relative "lib/snowflaked/version"

Gem::Specification.new do |spec|
  spec.name = "snowflaked"
  spec.version = Snowflaked::VERSION
  spec.authors = ["Luiz Eduardo Kowalski"]

  spec.summary = "Fast Snowflake ID generator with Rust backend"
  spec.description = "A Ruby gem for generating Twitter Snowflake IDs using a high-performance Rust backend. Thread-safe with configurable machine ID and custom epoch support."
  spec.homepage = "https://github.com/luizkowalski/snowflaked"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGES.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*",
    "ext/**/*",
    "Cargo.toml",
    "LICENSE.txt",
    "README.md"
  ]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/snowflaked/extconf.rb"]

  spec.add_dependency "rb_sys", "~> 0.9"
end
