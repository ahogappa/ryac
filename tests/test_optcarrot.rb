# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'tempfile'
require 'fileutils'
require 'rbconfig'
require_relative '../lib/ruby_minify'

# Optcarrot is what defines the aggressive end of the supported range: a real
# program, minified at L4, has to keep producing the same frames.
#
# It is also the reason L5 stops here. Optcarrot builds its CPU and PPU cores as
# source text and evals them, scans that text for `@ivar` names with a regexp,
# dispatches through `send(computed_symbol)`, and requires its drivers by an
# interpolated path. Method names survive inside strings and symbols there, so
# method renaming cannot be applied to it by any static analysis — the ceiling
# is a property of the program, not a defect to fix.
#
# Excluded from the default `rake test` — run with `rake test:optcarrot`.
class TestOptcarrot < Minitest::Test
  OPTCARROT_DIR = File.expand_path('../gem_tests/optcarrot', __dir__)
  ENTRY = File.join(OPTCARROT_DIR, 'lib', 'optcarrot.rb')
  ROM = File.join(OPTCARROT_DIR, 'examples', 'Lan_Master.nes')

  # The level Optcarrot is expected to survive. Raise this only when the
  # program itself stops defeating the transformation.
  SUPPORTED_LEVEL = 4

  def setup
    skip "optcarrot not cloned: #{OPTCARROT_DIR}" unless File.exist?(ENTRY) && File.exist?(ROM)
  end

  def test_minified_at_supported_level_renders_identical_frames
    baseline = run_benchmark([
      '-I', File.join(OPTCARROT_DIR, 'lib'),
      File.join(OPTCARROT_DIR, 'bin', 'optcarrot'),
      '--benchmark', ROM
    ])
    refute_nil baseline[:checksum], "baseline produced no checksum\n#{baseline[:stderr][0, 500]}"

    result = RubyMinify::Minifier.new.call(ENTRY, level: SUPPORTED_LEVEL)

    Dir.mktmpdir('optcarrot_minify') do |dir|
      File.write(File.join(dir, 'optcarrot_min.rb'), result.content)
      File.write(File.join(dir, 'optcarrot_aliases.rb'), result.aliases)
      runner = File.join(dir, 'runner.rb')
      File.write(runner, <<~RUBY)
        ARGV.replace(["--benchmark", #{ROM.inspect}])
        require_relative "optcarrot_min"
        require_relative "optcarrot_aliases"
        Optcarrot::NES.new.run
      RUBY

      minified = run_benchmark([runner])
      refute_nil minified[:checksum],
                 "minified optcarrot produced no checksum at L#{SUPPORTED_LEVEL}\n#{minified[:stderr][0, 800]}"
      assert_equal baseline[:checksum], minified[:checksum],
                   "L#{SUPPORTED_LEVEL} changed the rendered output"
    end

    assert_operator result.stats.compression_ratio, :<, 0.75,
                    "expected a substantial reduction, got #{result.stats.compression_ratio}"
  end

  private

  # Runs with an unbundled env so the minified program is loaded on its own
  # terms — in particular without any gem the original only requires lazily.
  def run_benchmark(args)
    out = Tempfile.new('optcarrot_out')
    err = Tempfile.new('optcarrot_err')
    out.close
    err.close
    pid = Bundler.with_unbundled_env do
      spawn(RbConfig.ruby, *args, out: [out.path, 'w'], err: [err.path, 'w'])
    end
    waiter = Thread.new { Process.wait2(pid) }
    unless waiter.join(300)
      Process.kill('TERM', pid)
      waiter.join
    end
    stdout = File.read(out.path)
    { checksum: stdout[/^checksum:\s*(\d+)/, 1], stdout: stdout, stderr: File.read(err.path) }
  ensure
    out&.unlink
    err&.unlink
  end
end
