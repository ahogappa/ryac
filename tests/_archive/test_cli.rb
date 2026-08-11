# frozen_string_literal: true

require_relative 'test_helper'

class TestCLI < Minitest::Test
  MINIFY_BIN = File.expand_path('../bin/ryac', __dir__)

  def test_version_flag
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--version')
    assert status.success?
    assert_match(/ruby-minify version \d+\.\d+\.\d+/, stdout.strip)
  end

  def test_help_flag
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--help')
    assert status.success?
    assert_match(/Usage: minify/, stdout)
    assert_match(/--output/, stdout)
    assert_match(/--aliases/, stdout)
  end

  def test_no_arguments_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN)
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/No entry file specified/, stderr)
  end

  def test_nonexistent_file_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '/tmp/nonexistent_file_xyz.rb')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/File not found/, stderr)
  end

  def test_invalid_option_prints_error
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '--invalid-option')
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_match(/invalid option/, stderr)
  end

  def test_minify_simple_file
    Tempfile.create(['test_cli', '.rb']) do |f|
      f.write("puts 'hello world'")
      f.flush

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, f.path)
      assert status.success?, "minify failed: #{stderr}"
      assert_match(/hello world/, stdout)
      assert_match(/Compression:/, stderr)
      assert_match(/Files processed:/, stderr)
    end
  end

  def test_output_flag_writes_to_file
    Tempfile.create(['test_cli_input', '.rb']) do |input|
      input.write("x = 1 + 2\nputs x")
      input.flush

      Tempfile.create(['test_cli_output', '.rb']) do |output|
        _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '-o', output.path, input.path)
        assert status.success?, "minify failed: #{stderr}"

        content = File.read(output.path)
        refute content.empty?, "Output file is empty"
      end
    end
  end

  def test_aliases_flag_separates_output
    Tempfile.create(['test_cli_input', '.rb']) do |input|
      input.write("class MyLongClassName\n  def hello\n    puts 'hi'\n  end\nend\nMyLongClassName.new.hello")
      input.flush

      Tempfile.create(['test_cli_aliases', '.rb']) do |aliases_file|
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, '-a', aliases_file.path, input.path)
        assert status.success?, "minify failed: #{stderr}"
        # Main output should not contain aliases when -a is used
        refute stdout.empty?, "Main output should not be empty"
      end
    end
  end

  def test_syntax_error_exit_code
    Tempfile.create(['test_cli_syntax_error', '.rb']) do |f|
      f.write("def foo(\n  bar\nend end end")
      f.flush

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, MINIFY_BIN, f.path)
      refute status.success?
      assert_equal 2, status.exitstatus
      assert_match(/[Ee]rror/, stderr)
    end
  end
end
