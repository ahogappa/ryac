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

  # Minifying optcarrot dominates the runtime of every test here; share one
  # result across them.
  def self.minified_result
    @minified_result ||= RubyMinify::Minifier.new.call(ENTRY, level: SUPPORTED_LEVEL)
  end

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

    result = self.class.minified_result

    in_minified_dir(result) do |dir|
      runner = write_runner(dir, ['--benchmark', ROM])

      minified = run_benchmark([runner])
      refute_nil minified[:checksum],
                 "minified optcarrot produced no checksum at L#{SUPPORTED_LEVEL}\n#{minified[:stderr][0, 800]}"
      assert_equal baseline[:checksum], minified[:checksum],
                   "L#{SUPPORTED_LEVEL} changed the rendered output"
    end

    assert_operator result.stats.compression_ratio, :<, 0.75,
                    "expected a substantial reduction, got #{result.stats.compression_ratio}"
  end

  # An unattended demo run never reads the pads, so it cannot catch a
  # minification bug in anything the player reaches by playing: pad register
  # reads, the title-to-game transition, movement logic. This drives the same
  # recorded button script (optcarrot's own log-input driver) through the
  # baseline and the minified build and demands pixel-identical results —
  # after first proving the script visibly changes the screen at all.
  def test_minified_at_supported_level_survives_scripted_input
    Dir.mktmpdir('optcarrot_input') do |dir|
      key_log = File.join(dir, 'key_log.dat')
      File.binwrite(key_log, Marshal.dump(scripted_pad_states))

      scripted_args = [
        '--video', 'none', '--audio', 'none',
        '--input', 'log', '--key-log', key_log,
        '--print-video-checksum', '--frames', SCRIPT_FRAMES.to_s, ROM
      ]
      idle_args = [
        '--video', 'none', '--audio', 'none', '--input', 'none',
        '--print-video-checksum', '--frames', SCRIPT_FRAMES.to_s, ROM
      ]
      optcarrot = ['-I', File.join(OPTCARROT_DIR, 'lib'), File.join(OPTCARROT_DIR, 'bin', 'optcarrot')]

      baseline = run_benchmark(optcarrot + scripted_args)
      refute_nil baseline[:checksum], "scripted baseline produced no checksum\n#{baseline[:stderr][0, 500]}"

      idle = run_benchmark(optcarrot + idle_args)
      refute_equal idle[:checksum], baseline[:checksum],
                   'button script left the screen identical to the idle run — the input never reached the game'

      in_minified_dir(self.class.minified_result) do |min_dir|
        # The log-input driver is loaded with a require_relative computed at
        # runtime, which concatenation cannot follow, so the minified build
        # needs a driver file beside it. It cannot be optcarrot's own: that
        # one reads @conf and Pad::* from the base classes, whose ivars and
        # constants L4 legitimately renames. This shim replays the same log
        # through nothing but stable seams — the init/tick driver interface
        # (method names survive L4) and the raw pad bit indices.
        FileUtils.mkdir_p(File.join(min_dir, 'driver'))
        File.write(File.join(min_dir, 'driver', 'log_input.rb'), <<~RUBY)
          module Optcarrot
            class LogInput < Input
              def init
                @replay_log = Marshal.load(File.binread(ENV.fetch("OPTCARROT_KEY_LOG")))
                @replay_prev = 0
              end

              def dispose
              end

              def tick(frame, pads)
                state = @replay_log[frame] || 0
                8.times do |i|
                  if @replay_prev[i] == 0 && state[i] == 1
                    pads.keydown(0, i)
                  elsif @replay_prev[i] == 1 && state[i] == 0
                    pads.keyup(0, i)
                  end
                end
                @replay_prev = state
              end
            end
          end
        RUBY

        runner = write_runner(min_dir, scripted_args, env: { 'OPTCARROT_KEY_LOG' => key_log })
        minified = run_benchmark([runner])
        refute_nil minified[:checksum],
                   "minified optcarrot produced no checksum under scripted input\n#{minified[:stderr][0, 800]}"
        assert_equal baseline[:checksum], minified[:checksum],
                     "L#{SUPPORTED_LEVEL} changed the rendered output under scripted input"
      end
    end
  end

  private

  # Pad bit positions, mirroring Optcarrot::Pad.
  PAD_A     = 1 << 0
  PAD_START = 1 << 3
  PAD_UP    = 1 << 4
  PAD_DOWN  = 1 << 5
  PAD_LEFT  = 1 << 6
  PAD_RIGHT = 1 << 7

  SCRIPT_FRAMES = 450

  # Frame-indexed pad bitmasks: START out of the title screen (twice, in case
  # the first lands during a fade), then walk the character around and use A.
  # Held for 16 frames each so no game-side poll can miss them.
  def scripted_pad_states
    states = Array.new(SCRIPT_FRAMES, 0)
    {
      100 => PAD_START,
      200 => PAD_START,
      260 => PAD_RIGHT,
      290 => PAD_DOWN,
      320 => PAD_A,
      350 => PAD_LEFT,
      380 => PAD_UP,
      410 => PAD_RIGHT | PAD_A
    }.each do |frame, mask|
      16.times { |i| states[frame + i] = mask }
    end
    states
  end

  def in_minified_dir(result)
    Dir.mktmpdir('optcarrot_minify') do |dir|
      File.write(File.join(dir, 'optcarrot_min.rb'), result.content)
      File.write(File.join(dir, 'optcarrot_aliases.rb'), result.aliases)
      yield dir
    end
  end

  def write_runner(dir, args, env: {})
    runner = File.join(dir, 'runner.rb')
    env_lines = env.map { |k, v| "ENV[#{k.inspect}] = #{v.inspect}" }.join("\n")
    File.write(runner, <<~RUBY)
      #{env_lines}
      ARGV.replace(#{args.inspect})
      require_relative "optcarrot_min"
      require_relative "optcarrot_aliases"
      Optcarrot::NES.new.run
    RUBY
    runner
  end

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
