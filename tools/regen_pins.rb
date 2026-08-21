# frozen_string_literal: true

# Regenerates the exact-byte pins in tests/ryac/levels/test_level*.rb from
# the current pipeline. The level tests are the model: run this after a
# deliberate behavior change, then review the pin diff — a surprising hunk
# is a caught bug, never a reason to loosen an assertion (see CLAUDE.md).
#
#   ruby tools/regen_pins.rb

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'lib')
require 'ryac'
# The level tests run these exact recipes; regenerating from the same
# table is what keeps the pins reproducible by a test run.
require_relative '../tests/support/stage_recipes'

CODE = File.read(File.join(ROOT, 'tests/fixtures/level_test_code.rb'), encoding: Encoding::UTF_8)

RECIPES = MinifyTestHelper::STAGE_RECIPES

# Cosmetic chunking in the pins' style: break after ';' when a natural
# statement head follows. Lossless by construction (join == original).
def chunk(code)
  lines = code.gsub(/;(?=(?:def |class |module |alias |attr|puts |end;|define_))/, ";\n").split("\n")
  raise 'chunking lost bytes' unless lines.join == code
  lines
end

RECIPES.each do |level, stages|
  result = Ryac::Minifier.run_stages(CODE, stages)
  path = File.join(ROOT, "tests/ryac/levels/test_level#{level}.rb")
  text = File.read(path, encoding: Encoding::UTF_8)

  entries = chunk(result.code).map { |line| "      #{line.inspect}," }.join("\n")
  block = "expected = [\n#{entries}\n    ].join('')"
  new_text = text.sub(/expected = \[.*?\]\.join\(''\)/m) { block }
  raise "expected block not found in #{path}" if new_text == text && !text.include?(block)

  pre = "assert_equal #{result.preamble.inspect.tr('"', "'")}, result.preamble"
  new_text = new_text.sub(/assert_equal '.*?', result\.preamble/) { pre }
  ali = "assert_equal #{result.aliases.inspect.tr('"', "'")}, result.aliases"
  new_text = new_text.sub(/assert_equal '.*?', result\.aliases/) { ali }
  File.write(path, new_text)
  puts "level #{level}: code=#{result.code.bytesize}B preamble=#{result.preamble.bytesize}B aliases=#{result.aliases.bytesize}B"
end
