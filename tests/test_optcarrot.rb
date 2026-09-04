# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'tempfile'
require 'fileutils'
require 'rbconfig'
require_relative '../lib/ryac'
require_relative 'support/constant_audit'

# Optcarrot is what defines the aggressive end of the supported range: a real
# program, minified at L4, has to keep producing the same frames.
#
# It is also the reason L5 stops here. Optcarrot builds its CPU and PPU cores as
# source text and evals them, scans that text for `@ivar` names with a regexp,
# and dispatches through `send(computed_symbol)`. Method names survive inside
# strings and symbols there, so method renaming cannot be applied to it by any
# static analysis — the ceiling is a property of the program, not a defect to
# fix. Its drivers, required by an interpolated path, are bundled as lazy
# regions and renamed with the core.
#
# Coverage comes in three layers. The benchmark test replays optcarrot's own
# canonical 180-frame demo and compares the final checksum. The scenario tests
# then actually play the game — an unattended demo never reads the pads, so it
# cannot catch a minification bug in anything the player reaches by playing —
# and compare a per-frame digest of every rendered frame, so a single broken
# frame anywhere in the run fails the test and names the frame. Both use the
# built-in none drivers; the bin test crosses the driver boundary the way a
# player does — upstream's own bin/optcarrot over the bundle, png and wav
# drivers loaded from the bundle's regions — and compares what they write.
#
# Excluded from the default `rake test` — run with `rake test:optcarrot`.
class TestOptcarrot < Minitest::Test
  OPTCARROT_DIR = File.expand_path('../gem_tests/optcarrot', __dir__)
  OPTCARROT_LIB = File.join(OPTCARROT_DIR, 'lib')
  ENTRY = File.join(OPTCARROT_LIB, 'optcarrot.rb')
  ROM = File.join(OPTCARROT_DIR, 'examples', 'Lan_Master.nes')

  # The level Optcarrot is expected to survive. Raise this only when the
  # program itself stops defeating the transformation.
  SUPPORTED_LEVEL = :stable

  # Pad bit positions, mirroring Optcarrot::Pad.
  PAD_A      = 1 << 0
  PAD_B      = 1 << 1
  PAD_SELECT = 1 << 2
  PAD_START  = 1 << 3
  PAD_UP     = 1 << 4
  PAD_DOWN   = 1 << 5
  PAD_LEFT   = 1 << 6
  PAD_RIGHT  = 1 << 7

  # Button scripts as [start_frame, held_for, mask] presses, built around
  # Lan Master's actual flow (verified frame-by-frame against PNG dumps of
  # the baseline): START engages the title menu, a second START enters
  # LEVEL01 — which opens on its RESUME/RESTART menu — and A resumes into
  # the board, where the cursor sits on the piece cluster and A rotates the
  # piece under it.
  #
  # Distinct scenarios exercise distinct machinery: the playthrough walks
  # the cursor across the pieces and rotates them (board state, sprite and
  # HUD redraws, the countdown timer); pause stress toggles the in-game menu
  # against held directions; button mash flips pad bits every frame and
  # holds impossible chords, the worst case for the strobe/latch path.
  ENTER_GAMEPLAY = [
    [100, 12, PAD_START],
    [160, 12, PAD_START],
    [220, 12, PAD_A]
  ].freeze

  SCENARIOS = {
    playthrough: {
      frames: 780,
      presses: ENTER_GAMEPLAY + [
        [280, 8, PAD_RIGHT], [300, 8, PAD_RIGHT], [320, 8, PAD_UP],   # walk onto the pieces
        [340, 8, PAD_A], [360, 8, PAD_A],                             # rotate one twice
        [380, 8, PAD_RIGHT], [400, 8, PAD_A],                         # neighbor piece
        [420, 8, PAD_DOWN], [440, 8, PAD_LEFT], [460, 8, PAD_A],
        [480, 8, PAD_UP], [500, 8, PAD_A],
        [530, 8, PAD_LEFT], [545, 8, PAD_LEFT], [560, 8, PAD_DOWN], [575, 8, PAD_A],
        [610, 20, PAD_RIGHT],                                         # medium hold
        [650, 8, PAD_B], [670, 8, PAD_SELECT],                        # unused-button paths
        [700, 8, PAD_A]
      ]
    },
    pause_stress: {
      frames: 620,
      presses: ENTER_GAMEPLAY + [
        [280, 180, PAD_RIGHT],                                        # held across the pauses
        [300, 10, PAD_RIGHT | PAD_START], [340, 10, PAD_RIGHT | PAD_A],
        [400, 10, PAD_RIGHT | PAD_START], [440, 10, PAD_RIGHT | PAD_A],
        [520, 10, PAD_START], [550, 10, PAD_A]
      ]
    },
    button_mash: {
      frames: 420,
      presses: ENTER_GAMEPLAY +
               (260..320).map { |f| [f, 1, f.even? ? PAD_A : PAD_B] } +  # alternate every frame
               [[340, 5, PAD_UP | PAD_A], [345, 5, PAD_DOWN | PAD_B],
                [350, 5, PAD_LEFT | PAD_A | PAD_B], [355, 5, PAD_RIGHT | PAD_SELECT],
                [370, 20, 0xFF]]                                         # every bit at once
    }
  }.freeze

  def self.minified_result
    @minified_result ||= Ryac::Minifier.new.call(ENTRY, level: SUPPORTED_LEVEL)
  end

  def setup
    skip "optcarrot not cloned: #{OPTCARROT_DIR}" unless File.exist?(ENTRY) && File.exist?(ROM)
  end

  # Optcarrot's own benchmark flow, exactly as upstream runs it.
  def test_minified_at_supported_level_renders_identical_frames
    baseline = run_ruby([
      '-I', OPTCARROT_LIB,
      File.join(OPTCARROT_DIR, 'bin', 'optcarrot'),
      '--benchmark', ROM
    ])
    baseline_checksum = baseline[:stdout][/^checksum:\s*(\d+)/, 1]
    refute_nil baseline_checksum, "baseline produced no checksum\n#{baseline[:stderr][0, 500]}"

    result = self.class.minified_result

    in_minified_dir(result) do |dir|
      runner = File.join(dir, 'runner.rb')
      File.write(runner, <<~RUBY)
        ARGV.replace(["--benchmark", #{ROM.inspect}])
        require_relative "optcarrot_min"
        require_relative "optcarrot_aliases"
        Optcarrot::NES.new.run
      RUBY

      minified = run_ruby([runner])
      minified_checksum = minified[:stdout][/^checksum:\s*(\d+)/, 1]
      refute_nil minified_checksum,
                 "minified optcarrot produced no checksum at #{SUPPORTED_LEVEL}\n#{minified[:stderr][0, 800]}"
      assert_equal baseline_checksum, minified_checksum,
                   "#{SUPPORTED_LEVEL} minification changed the rendered output"
    end

    assert_operator result.stats.compression_ratio, :<, 0.75,
                    "expected a substantial reduction, got #{result.stats.compression_ratio}"
  end

  # The bundle standing in for lib/optcarrot.rb under upstream's unmodified
  # bin/optcarrot, with the png and wav drivers running out of the bundle's
  # regions: the frame and the samples they write must match the original's
  # byte for byte. The digest runs never cross this boundary — the none
  # drivers are core code — and it is the one a user crosses first.
  def test_bin_optcarrot_runs_the_bundle_with_its_drivers
    args = ['--video', 'png', '--audio', 'wav', '--input', 'none', '--frames', '60', ROM]
    baseline = Dir.mktmpdir('optcarrot_bin_baseline') do |dir|
      run_ruby(['-I', OPTCARROT_LIB, File.join(OPTCARROT_DIR, 'bin', 'optcarrot'), *args], chdir: dir)
      driver_outputs(dir)
    end
    refute_nil baseline[0], 'baseline wrote no video.png'

    bundled = Dir.mktmpdir('optcarrot_bin_bundle') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'lib'))
      FileUtils.mkdir_p(File.join(dir, 'bin'))
      File.write(File.join(dir, 'lib', 'optcarrot.rb'), self.class.minified_result.full_content)
      FileUtils.cp(File.join(OPTCARROT_DIR, 'bin', 'optcarrot'), File.join(dir, 'bin', 'optcarrot'))
      result = run_ruby([File.join(dir, 'bin', 'optcarrot'), *args], chdir: dir)
      outputs = driver_outputs(dir)
      refute_nil outputs[0], "the bundle wrote no video.png under bin/optcarrot\n#{result[:stderr][0, 800]}"
      outputs
    end

    assert_equal baseline[0], bundled[0], 'the png driver out of the bundle rendered a different last frame'
    assert_equal baseline[1], bundled[1], 'the wav driver out of the bundle wrote different samples'
  end

  SCENARIOS.each_key do |name|
    define_method(:"test_scripted_#{name}_renders_identical_frames") do
      assert_scenario_frames_identical(name)
    end
  end

  # Frame comparison only certifies the paths the scenarios execute; a
  # constant reference broken on an unexercised path (a debug flag, an
  # alternate video backend) would stay latent. Statically, every constant
  # reference in the artifact must resolve somewhere — its own definitions
  # or the constants its requires provide.
  def test_every_constant_reference_in_the_artifact_resolves
    result = self.class.minified_result
    # StackProf is optcarrot's own optional profiler dependency (required
    # only when --stackprof-mode is passed), and FFI is what the sdl2, sfml
    # and ao drivers require at the top of their regions; both resolve only
    # where the gem is installed, so they would flip this test between
    # machines without being minifier damage.
    issues = ConstantAudit.unresolved(result.content, extra_source: result.aliases,
                                      allow: %w[StackProf FFI])
    assert_empty issues.map { |path, line| "#{path} (line #{line})" },
                 'constant references in the minified optcarrot resolve nowhere — latent NameError'
  end

  # The button script must visibly change the run at all, or the scenario
  # tests silently degrade into three copies of the demo test.
  def test_scripts_reach_the_game
    scenario = SCENARIOS[:playthrough]
    idle = baseline_digests(:idle, frames: scenario[:frames], key_log: nil)
    scripted = baseline_digests(:playthrough, frames: scenario[:frames], key_log: write_key_log(:playthrough))
    refute_equal idle, scripted,
                 'button script left every frame identical to the idle run — the input never reached the game'
  end

  private

  def assert_scenario_frames_identical(name)
    scenario = SCENARIOS[name]
    key_log = write_key_log(name)

    baseline = baseline_digests(name, frames: scenario[:frames], key_log: key_log)
    minified = minified_digests(name, frames: scenario[:frames], key_log: key_log)

    assert_equal scenario[:frames], baseline.size, "baseline rendered #{baseline.size} frames, expected #{scenario[:frames]}"
    # If the screen barely changes, the script no longer reaches the game
    # (e.g. the menu flow changed upstream) and the comparison is vacuous.
    assert_operator baseline.uniq.size, :>=, 10,
                    "scenario #{name}: only #{baseline.uniq.size} distinct frames — script is stuck outside gameplay"

    return if baseline == minified

    first = baseline.zip(minified).index { |a, b| a != b } || [baseline.size, minified.size].min
    flunk "scenario #{name}: frames diverge at frame #{first}/#{scenario[:frames]} " \
          "(baseline=#{baseline[first].inspect}, minified=#{minified[first].inspect}, " \
          "pad mask at that frame=#{pad_states(name)[first].inspect})"
  end

  def pad_states(name)
    scenario = SCENARIOS[name]
    states = Array.new(scenario[:frames], 0)
    scenario[:presses].each do |start, held, mask|
      held.times { |i| states[start + i] |= mask if start + i < states.size }
    end
    states
  end

  def write_key_log(name)
    @key_logs ||= {}
    @key_logs[name] ||= begin
      dir = (@key_log_dir ||= Dir.mktmpdir('optcarrot_keylog'))
      path = File.join(dir, "#{name}.dat")
      File.binwrite(path, Marshal.dump(pad_states(name)))
      path
    end
  end

  # Digest every rendered frame by prepending onto the Video driver — the
  # same seam on both builds (`tick` survives L4; the aliases file restores
  # the class name on the minified side).
  DIGEST_PRELUDE = <<~RUBY
    FRAME_DIGESTS = []
    module FrameDigestCapture
      def tick(output)
        FRAME_DIGESTS << output.sum
        super
      end
    end
    Optcarrot::Video.prepend(FrameDigestCapture)
    at_exit { puts "digests:" + FRAME_DIGESTS.join(",") }
  RUBY

  def scenario_argv(frames, key_log)
    args = ['--video', 'none', '--audio', 'none', '--frames', frames.to_s]
    args += ['--input', 'log', '--key-log', key_log] if key_log
    args += ['--input', 'none'] unless key_log
    args + [ROM]
  end

  def baseline_digests(label, frames:, key_log:)
    dir = (@baseline_dir ||= Dir.mktmpdir('optcarrot_baseline'))
    runner = File.join(dir, "baseline_#{label}.rb")
    File.write(runner, <<~RUBY)
      $LOAD_PATH.unshift #{OPTCARROT_LIB.inspect}
      require "optcarrot"
      #{DIGEST_PRELUDE}
      ARGV.replace(#{scenario_argv(frames, key_log).inspect})
      Optcarrot::NES.new.run
    RUBY
    parse_digests(run_ruby([runner]), "baseline #{label}")
  end

  # The log-input driver replaying the script is optcarrot's own, running
  # out of the bundle's region — it reads @conf and Pad::* from the base
  # classes, renamed together with them.
  def minified_digests(label, frames:, key_log:)
    digests = nil
    in_minified_dir(self.class.minified_result) do |dir|
      runner = File.join(dir, "minified_#{label}.rb")
      File.write(runner, <<~RUBY)
        ARGV.replace(#{scenario_argv(frames, key_log).inspect})
        require_relative "optcarrot_min"
        require_relative "optcarrot_aliases"
        #{DIGEST_PRELUDE}
        Optcarrot::NES.new.run
      RUBY
      digests = parse_digests(run_ruby([runner]), "minified #{label}")
    end
    digests
  end

  def parse_digests(result, label)
    line = result[:stdout][/^digests:([\d,]*)$/, 1]
    refute_nil line, "#{label} produced no frame digests\n#{result[:stderr][0, 800]}"
    line.split(',').map { |d| Integer(d) }
  end

  # What the png and wav drivers wrote into dir, nil where a file is missing.
  def driver_outputs(dir)
    %w[video.png audio.wav].map do |name|
      path = File.join(dir, name)
      File.exist?(path) ? File.binread(path) : nil
    end
  end

  def in_minified_dir(result)
    Dir.mktmpdir('optcarrot_minify') do |dir|
      File.write(File.join(dir, 'optcarrot_min.rb'), result.content)
      File.write(File.join(dir, 'optcarrot_aliases.rb'), result.aliases)
      yield dir
    end
  end

  # Runs with an unbundled env so the minified program is loaded on its own
  # terms — in particular without any gem the original only requires lazily.
  def run_ruby(args, chdir: Dir.pwd)
    out = Tempfile.new('optcarrot_out')
    err = Tempfile.new('optcarrot_err')
    out.close
    err.close
    pid = Bundler.with_unbundled_env do
      spawn(RbConfig.ruby, *args, out: [out.path, 'w'], err: [err.path, 'w'], chdir: chdir)
    end
    waiter = Thread.new { Process.wait2(pid) }
    unless waiter.join(300)
      Process.kill('TERM', pid)
      waiter.join
    end
    { stdout: File.read(out.path), stderr: File.read(err.path) }
  ensure
    out&.unlink
    err&.unlink
  end
end
