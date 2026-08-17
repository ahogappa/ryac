# frozen_string_literal: true

require_relative '../test_helper'

class TestCLIGemOption < Minitest::Test
  MINIFY_BIN = File.expand_path('../../bin/ryac', __dir__)

  # The CLI is a thin shell over the library: its exact stdout/stderr are
  # derived by running the library on the same input in-process, so the
  # pins stay exact without hard-coding environment-dependent sizes.
  def expected_result_for(gem_names)
    args = Ryac::GemResolver.minifier_args(gem_names)
    Ryac::Minifier.new.call(
      args[:entry],
      level: :stable,
      project_root: args[:project_root],
      gem_names: gem_names,
      gem_require_paths: args[:gem_require_paths]
    )
  end

  def expected_stderr_for(result)
    "Compression: #{((1 - result.stats.compression_ratio) * 100).round(1)}%\n" \
      "Files processed: #{result.stats.file_count}\n"
  end

  def test_gem_flag_resolves_and_minifies
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json', '-c', 'stable')
    assert status.success?, "minify --gem json failed: #{stderr}"
    result = expected_result_for(['json'])
    assert_equal "#{result.full_content}\n", stdout
    assert_equal expected_stderr_for(result), stderr
  end

  def test_gem_flag_unknown_gem_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'nonexistent_gem_xyz_12345')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_equal "Error: Gem not found: nonexistent_gem_xyz_12345\n", stderr
  end

  def test_gem_flag_with_file_args_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json', 'foo.rb')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_equal "Error: Cannot specify both --gem and file arguments\n", stderr
  end

  def test_gem_flag_comma_separated_multiple_gems
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json,csv', '-c', 'stable')
    assert status.success?, "minify --gem json,csv failed: #{stderr}"
    result = expected_result_for(%w[json csv])
    assert_equal "#{result.full_content}\n", stdout
    assert_equal expected_stderr_for(result), stderr
  end

  def test_gem_flag_comma_separated_with_unknown_gem_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--gem', 'json,nonexistent_xyz')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_equal "Error: Gem not found: nonexistent_xyz\n", stderr
  end

  def test_help_shows_gem_option
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--help')
    assert status.success?
    assert_equal <<~HELP, stdout
      Usage: minify [options] [FILE...]
          -o, --output FILE                Write output to FILE instead of stdout
          -a, --aliases FILE               Write constant alias declarations to FILE
          -g, --gem GEM_NAMES              Minify installed gem(s) by name (comma-separated)
          -c, --compress LEVEL             Set compression level (stable or unstable)
          -h, --help                       Display this help message
          -v, --version                    Display version
    HELP
  end
end
