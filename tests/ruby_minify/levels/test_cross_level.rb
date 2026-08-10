# frozen_string_literal: true

require_relative 'level_test_helper'

class TestCrossLevel < Minitest::Test
  include MinifyTestHelper
  include LevelTestHelper

  def test_default_level_is_stable
    assert_equal :stable, RubyMinify::Minifier::DEFAULT_LEVEL
  end

  def test_exactly_two_levels
    assert_equal %i[stable unstable], RubyMinify::Minifier::STAGES.keys
  end

  # Compression should be monotonically non-increasing as the recipes (and
  # finally the two levels) add steps
  def test_monotonic_compression
    sizes = (0..5).map { |l| minify_at_level(LEVEL_TEST_CODE, l, verify_output: false).code.bytesize }
    sizes.each_cons(2) do |higher, lower|
      assert_operator higher, :>=, lower,
        "Level compression should be monotonically non-increasing: #{sizes.inspect}"
    end
  end
end
