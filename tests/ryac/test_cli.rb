# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'

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
          -p, --pack FORMAT                Emit a self-extracting file (self or zlib)
          -d, --driver FILE                Keep the program a library and write its driver to FILE (ruby FILE CORE --exec EXPR)
          -h, --help                       Display this help message
          -v, --version                    Display version
    HELP
  end

  LAZY_FIXTURE = File.expand_path('../fixtures/lazy_plugins/main.rb', __dir__)

  # The two-file layout on the lazy_plugins fixture: the core is the
  # program as a library (its launch is guarded), the driver is ryac's
  # fixed file, which supplies the loader, loads the core and starts the
  # program with --exec, its own arguments gone from ARGV and everything
  # after "--" untouched. The expression is code outside the bundle: it
  # spells the skeleton (aliased) and an entry point no code in the bundle
  # calls, which the safe policy therefore never renames.
  def test_driver_option_writes_the_core_as_a_library_and_the_fixed_driver
    Dir.mktmpdir do |dir|
      core = File.join(dir, 'minify.rb')
      driver = File.join(dir, 'driver.rb')
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, LAZY_FIXTURE, '-o', core, '--driver', driver)
      assert status.success?, "minify --driver failed: #{stderr}"
      result = Ryac::Minifier.new.call(LAZY_FIXTURE, level: :stable, driver: true)
      assert_equal expected_stderr_for(result), stderr

      assert_equal result.full_content, File.read(core)
      assert_equal Ryac::DriverFile::SOURCE, File.read(driver)

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, driver, core,
        '--exec', 'p(Engine::Loader.boot(:turbo) || Engine::Loader.boot(:plain)); p ARGV',
        'game.nes', '--', '--exec', 'ignored'
      )
      assert status.success?, "the runner failed: #{stderr}"
      assert_equal "[15, 25, 35]\n[\"game.nes\", \"--\", \"--exec\", \"ignored\"]\n", stdout
    end
  end

  def test_driver_option_needs_an_output_file
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, LAZY_FIXTURE, '--driver', 'driver.rb')
    assert_equal 1, status.exitstatus
    assert_equal "Error: --driver needs -o for the core file\n", stderr
  end

  def test_driver_option_rejects_aliases_file_and_pack
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, LAZY_FIXTURE, '-o', 'x.rb', '-a', 'a.rb', '--driver', 'd.rb')
    assert_equal 1, status.exitstatus
    assert_equal "Error: --driver cannot be combined with -a (the runner loads the core with its aliases)\n", stderr

    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, LAZY_FIXTURE, '-o', 'x.rb', '--pack', 'self', '--driver', 'd.rb')
    assert_equal 1, status.exitstatus
    assert_equal "Error: --driver cannot be combined with --pack (a packed core cannot be loaded)\n", stderr
  end

  def test_driver_option_needs_a_program_with_lazy_regions
    Dir.mktmpdir do |dir|
      entry = File.expand_path('../fixtures/multi_file/independent_a.rb', __dir__)
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, entry, '-o', File.join(dir, 'x.rb'), '--driver', File.join(dir, 'd.rb'))
      assert_equal 2, status.exitstatus
      assert_equal "Error: cannot write a driver file: the program has no lazy regions\n", stderr
      refute File.exist?(File.join(dir, 'x.rb'))
    end
  end
end
