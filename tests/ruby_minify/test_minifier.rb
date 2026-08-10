# frozen_string_literal: true

require_relative '../test_helper'

class TestMinifier < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('minifier_test')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_call_simple_file
    path = File.join(@tmpdir, 'simple.rb')
    File.write(path, "def hello\n  puts \"hello\"\nend\nhello\n")

    minifier = RubyMinify::Minifier.new
    result = minifier.call(path, level: [])

    assert_equal 'def hello;puts("hello");end;hello', result.content
    assert_equal '', result.aliases
    assert_equal '', result.preamble
    assert_equal 35, result.stats.original_size
    assert_equal 33, result.stats.minified_size
    assert_equal 1, result.stats.file_count
    assert_equal result, minifier.result
  end

  def test_call_with_stdlib_require
    path = File.join(@tmpdir, 'with_stdlib.rb')
    File.write(path, "require \"json\"\nputs JSON.generate({a: 1})\n")

    minifier = RubyMinify::Minifier.new
    result = minifier.call(path, level: [])

    assert_equal "require \"json\";puts(JSON.generate({a:1}))", result.content
    assert_equal 42, result.stats.original_size
    assert_equal 41, result.stats.minified_size
  end
end
