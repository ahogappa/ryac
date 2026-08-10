# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'tmpdir'

class TestIntegration < Minitest::Test
  include MinifyTestHelper

  LIB_ENTRY = File.expand_path('../lib/ruby_minify.rb', __dir__)

  # Minifying the minifier dominates this file's runtime; every test shares
  # one build of the :unstable artifact.
  def self.unstable_artifact
    @unstable_artifact ||= RubyMinify::Minifier.new.call(LIB_ENTRY, level: :unstable)
  end

  # ===============================================
  # Self-Hosting Test (Bootstrap Test)
  # ===============================================
  # True self-hosting: minified minifier can minify itself again,
  # and the result is functionally equivalent.

  def test_self_hosting
    # Step 1: Minify the minifier source using original minifier (multi-file mode)
    result1 = self.class.unstable_artifact

    # Verify minified code is valid Ruby
    require 'prism'
    parse_result = Prism.parse(result1.content)
    assert parse_result.errors.empty?,
           "Minified minifier should be valid Ruby: #{parse_result.errors.map(&:message).join(', ')}"

    Dir.mktmpdir do |tmpdir|
      # Write minified minifier to temp file
      minified_minifier_path = File.join(tmpdir, 'minified_minifier.rb')
      File.write(minified_minifier_path, result1.content)

      # Write aliases to a separate file so original names are available
      aliases_path = File.join(tmpdir, 'aliases.rb')
      File.write(aliases_path, result1.aliases)

      # Step 2: Use minified minifier to minify the ORIGINAL source code
      # The minified minifier should produce the same output as the original
      runner_code = <<~RUBY
        require '#{minified_minifier_path}'
        require '#{aliases_path}'
        minifier = RubyMinify::Minifier.new
        result = minifier.call('#{LIB_ENTRY}', level: :unstable)
        puts result.content
      RUBY

      result2_content, stderr, status = Open3.capture3('ruby', '-e', runner_code)

      assert status.success?,
             "Minified minifier should be able to minify original source: #{stderr}"

      # Step 3: Verify output1 == output2 (self-hosting property)
      assert_equal result1.content, result2_content.strip,
             "Minified minifier should produce identical output when minifying original source"

      # Step 4: Re-minification should be idempotent (same size)
      re_minifier = RubyMinify::Minifier.new
      result3 = re_minifier.call(minified_minifier_path, level: :unstable)
      RubyVM::InstructionSequence.compile(result3.content)
      assert_equal result1.content, result3.content,
             "Re-minification should be idempotent " \
             "(first=#{result1.content.bytesize}, re-minified=#{result3.content.bytesize}, " \
             "diff=#{result3.content.bytesize - result1.content.bytesize})"
    end
  end

  # ===============================================
  # Cross-Level Artifact Test
  # ===============================================
  # Self-hosting only ever exercises the artifact at the level it was built
  # at — the other level's stage list is dead code to it, and an
  # inconsistency there stays latent until a user runs it (the
  # AttrDeclShorten dispatch bug hid exactly that way: the stage-loop call
  # site renamed while the class's defs kept their names, and nothing
  # executed the pair until :unstable listed the stage). So: the minified
  # minifier must reproduce the original minifier's output byte for byte at
  # EVERY level, on a fixture that walks classes, constants, attrs,
  # keywords, and the RBS input path (also dead during self-hosting, whose
  # rbs_files are empty).

  CROSS_LEVEL_FIXTURE = <<~RUBY
    module Engine
      LIMIT = 50
      class Widget
        attr_accessor :current_value
        def initialize(start_value)
          @current_value = start_value
        end
        def bump_by(amount:)
          @current_value += amount
          self
        end
        def report
          "\#{@current_value}/\#{LIMIT}"
        end
      end
    end
    w = Engine::Widget.new(3)
    w.bump_by(amount: 4)
    w.current_value = w.current_value + 1
    puts w.report
  RUBY

  CROSS_LEVEL_RBS = <<~RBS
    module Engine
      class Widget
        def initialize: (Integer) -> void
        def bump_by: (amount: Integer) -> Widget
        def report: () -> String
      end
    end
  RBS

  SPLIT_MARKER = "\n--8<--\n"

  def test_minified_minifier_reproduces_every_level
    artifact = self.class.unstable_artifact

    Dir.mktmpdir do |tmpdir|
      minified_path = File.join(tmpdir, 'minified_minifier.rb')
      File.write(minified_path, artifact.content)
      aliases_path = File.join(tmpdir, 'aliases.rb')
      File.write(aliases_path, artifact.aliases)

      fixture_dir = File.join(tmpdir, 'app')
      Dir.mkdir(fixture_dir)
      fixture_path = File.join(fixture_dir, 'app.rb')
      File.write(fixture_path, CROSS_LEVEL_FIXTURE)
      Dir.mkdir(File.join(fixture_dir, 'sig'))
      File.write(File.join(fixture_dir, 'sig', 'app.rbs'), CROSS_LEVEL_RBS)

      RubyMinify::Minifier::STAGES.each_key do |level|
        expected = RubyMinify::Minifier.new.call(fixture_path, level: level, project_root: fixture_dir)

        runner_code = <<~RUBY
          require '#{minified_path}'
          require '#{aliases_path}'
          result = RubyMinify::Minifier.new.call('#{fixture_path}', level: :#{level}, project_root: '#{fixture_dir}')
          print result.content
          print #{SPLIT_MARKER.dump}
          print result.aliases
          print #{SPLIT_MARKER.dump}
          print result.preamble
        RUBY
        out, stderr, status = Open3.capture3('ruby', '-e', runner_code)
        assert status.success?,
               "minified minifier must run the :#{level} pipeline: #{stderr}"

        content, aliases, preamble = out.split(SPLIT_MARKER, 3)
        assert_equal expected.content, content,
               "minified minifier's :#{level} content must match the original's"
        assert_equal expected.aliases, aliases,
               "minified minifier's :#{level} aliases must match the original's"
        assert_equal expected.preamble, preamble,
               "minified minifier's :#{level} preamble must match the original's"
      end
    end
  end
end
