# frozen_string_literal: true

require_relative "lib/snowflaked/version"

Gem::Specification.new do |spec|
  spec.name = "snowflaked"
  spec.version = Snowflaked::VERSION
  spec.authors = ["Luiz Eduardo Kowalski"]

  spec.summary = "Ruby Snowflake ID generator"
  spec.description = "A Ruby thread-, Ractor-, and fork-safe Snowflake ID generator with configurable machine ID and custom epoch support."
  spec.homepage = "https://github.com/luizkowalski/snowflaked"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGES.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*",
    "LICENSE.txt",
    "README.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 8.0"
end
