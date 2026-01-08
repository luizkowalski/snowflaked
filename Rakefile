# frozen_string_literal: true

require "bundler/gem_tasks"
require "rb_sys/extensiontask"
require "rake/testtask"

desc "Build the gem"
task build: :compile

GEMSPEC = Gem::Specification.load("snowflaked.gemspec")

RbSys::ExtensionTask.new("snowflaked", GEMSPEC) do |ext|
  ext.lib_dir = "lib/snowflaked"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

desc "Run tests"
task :test
task default: %i[compile test]
