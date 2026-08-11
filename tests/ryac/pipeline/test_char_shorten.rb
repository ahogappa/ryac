# frozen_string_literal: true

require_relative '../../test_helper'

class TestCharShorten < Minitest::Test
  def setup
    @stage = Ryac::Pipeline::CharShorten.new
  end

  def test_single_letter
    assert_equal "?a", @stage.call('"a"')
  end

  def test_single_uppercase
    assert_equal "?Z", @stage.call('"Z"')
  end

  def test_single_digit
    assert_equal "?5", @stage.call('"5"')
  end

  def test_underscore
    assert_equal "?_", @stage.call('"_"')
  end

  def test_multi_char_unchanged
    assert_equal '"ab"', @stage.call('"ab"')
  end

  def test_empty_string_unchanged
    assert_equal '""', @stage.call('""')
  end

  def test_special_char_unchanged
    assert_equal '"!"', @stage.call('"!"')
  end

  def test_single_quote_shortened
    assert_equal "?a", @stage.call("'a'")
  end

  def test_space_not_shortened
    assert_equal '" "', @stage.call('" "')
  end

  def test_interpolated_string_unchanged
    input = '"#{x}"'
    assert_equal input, @stage.call(input)
  end

  def test_multiple_chars_in_code
    assert_equal 'x=?a;y=?b', @stage.call('x="a";y="b"')
  end
end
