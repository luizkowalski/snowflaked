# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
require "rails/test_help"

ActiveRecord::Schema.verbose = false
load Rails.root.join("db/schema.rb").to_s # Load the schema for the test database

module ForkHelpers
  def fork_and_collect(&block)
    IO.pipe do |read_io, write_io|
      pid = fork { write_child_payload(read_io, write_io, block) }
      write_io.close
      parse_child_payload(read_io.read, pid)
    end
  end

  private

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
