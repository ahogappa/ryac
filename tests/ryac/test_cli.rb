# frozen_string_literal: true

require_relative '../test_helper'

class TestCLIGemOption < Minitest::Test
  MINIFY_BIN = File.expand_path('../../bin/ryac', __dir__)

  def test_gem_flag_resolves_and_minifies
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json', '-c', 'stable')
    assert status.success?, "minify --gem json failed: #{stderr}"
    refute stdout.empty?, "Output should not be empty"
    assert_match(/Compression:/, stderr)
    assert_match(/Files processed:/, stderr)
  end

  def test_gem_flag_unknown_gem_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'nonexistent_gem_xyz_12345')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/Gem not found/, stderr)
  end

  def test_gem_flag_with_file_args_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json', 'foo.rb')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/Cannot specify both/, stderr)
  end

  def test_gem_flag_comma_separated_multiple_gems
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json,csv', '-c', 'stable')
    assert status.success?, "minify --gem json,csv failed: #{stderr}"
    refute stdout.empty?, "Output should not be empty"
    # Should process files from both gems
    file_count = stderr[/Files processed: (\d+)/, 1].to_i
    assert file_count > 2, "Multiple gems should produce more than 2 files, got #{file_count}"
  end

  def test_gem_flag_comma_separated_with_unknown_gem_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json,nonexistent_xyz')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/Gem not found/, stderr)
  end

  def test_help_shows_gem_option
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--help')
    assert status.success?
    assert_match(/--gem/, stdout)
  end
end
