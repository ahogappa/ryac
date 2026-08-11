# frozen_string_literal: true

require_relative 'test_helper'

class TestResolveLevel < Minitest::Test
  def test_the_two_levels_resolve
    assert_equal :stable, Ryac::Minifier.resolve_level('stable')
    assert_equal :unstable, Ryac::Minifier.resolve_level('unstable')
    assert_equal :stable, Ryac::Minifier.resolve_level(:stable)
  end

  def test_numbers_and_old_aliases_are_gone
    %w[0 3 5 min max unknown].each do |value|
      assert_raises(ArgumentError) { Ryac::Minifier.resolve_level(value) }
    end
  end
end

class TestCompressCLI < Minitest::Test
  MINIFY_BIN = File.expand_path('../bin/ryac', __dir__)

  def setup
    @input = Tempfile.new(['test_compress', '.rb'])
    @input.write("puts 'hello world'")
    @input.flush
  end

  def teardown
    @input.close!
  end

  def test_compress_rejects_numeric_level
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '-c', '3', @input.path)
    refute status.success?
    assert stderr.include?("Invalid compress level"), "Expected rejection of numeric level: #{stderr}"
  end

  def test_compress_with_stable
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '-c', 'stable', @input.path)
    assert status.success?, "minify failed: #{stderr}"
  end

  def test_compress_with_unstable
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '-c', 'unstable', @input.path)
    assert status.success?, "minify failed: #{stderr}"
  end

  def test_compress_long_form
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--compress', 'stable', @input.path)
    assert status.success?, "minify failed: #{stderr}"
  end

  def test_compress_invalid_value
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '-c', 'invalid', @input.path)
    refute status.success?
    assert stderr.include?("Invalid compress level"), "Expected 'Invalid compress level' in stderr: #{stderr}"
  end

  def test_help_shows_compress_option
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--help')
    assert status.success?
    assert stdout.include?("--compress"), "Expected '--compress' in help output"
  end
end
