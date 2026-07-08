# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("snowflaked/snowflaked")

makefile = File.read("Makefile")
File.write("Makefile", makefile) if makefile.gsub!('install_name_tool -id ""', 'install_name_tool -id "$(notdir $(DLLIB))"')
