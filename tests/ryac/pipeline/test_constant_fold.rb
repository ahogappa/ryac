# frozen_string_literal: true

require_relative '../../test_helper'

class TestConstantFold < Minitest::Test
  def setup
    @stage = Ryac::Pipeline::ConstantFold.new
  end

  def test_addition
    assert_equal "5", @stage.call("2+3")
  end

  def test_subtraction
    assert_equal "7", @stage.call("10-3")
  end

  def test_multiplication
    assert_equal "12", @stage.call("3*4")
  end

  def test_division
    assert_equal "3", @stage.call("9/3")
  end

  def test_modulo
    assert_equal "1", @stage.call("7%3")
  end

  def test_power
    assert_equal "8", @stage.call("2**3")
  end

  def test_left_shift
    assert_equal "256", @stage.call("1<<8")
  end

  def test_right_shift
    assert_equal "4", @stage.call("16>>2")
  end

  def test_bitwise_and
    assert_equal "8", @stage.call("12&10")
  end

  def test_bitwise_or
    assert_equal "14", @stage.call("12|10")
  end

  def test_bitwise_xor
    assert_equal "6", @stage.call("12^10")
  end

  def test_unary_minus
    assert_equal "-5", @stage.call("-5")
  end

  def test_nested_fold
    assert_equal "10", @stage.call("2+3+5")
  end

  def test_no_fold_when_longer
    # 1+2 = "3" (1 byte) vs "1+2" (3 bytes) → fold saves space
    assert_equal "3", @stage.call("1+2")
  end

  def test_division_by_zero_not_folded
    assert_equal "1/0", @stage.call("1/0")
  end

  def test_modulo_by_zero_not_folded
    assert_equal "1%0", @stage.call("1%0")
  end

  def test_non_numeric_unchanged
    assert_equal 'x+y', @stage.call("x+y")
  end

  def test_parenthesized_expression
    assert_equal "6", @stage.call("(2+1)*2")
  end

  def test_bitwise_ops_integer_only
    # Float with bitwise should not fold
    assert_equal "1.0<<2", @stage.call("1.0<<2")
  end

  def test_float_addition
    assert_equal "3.5", @stage.call("1.0+2.5")
  end

  def test_not_folded_when_result_not_shorter
    # 9+0 = "9" (1 byte) vs "9+0" (3 bytes) → fold
    assert_equal "9", @stage.call("9+0")
    # But result "100" (3 bytes) vs "10*10" (5 bytes) → fold
    assert_equal "100", @stage.call("10*10")
  end

  def test_result_same_length_not_folded
    # 9*9 = "81" (2 bytes) vs "9*9" (3 bytes) → fold (shorter)
    assert_equal "81", @stage.call("9*9")
  end

  def test_unary_minus_float
    assert_equal "-3.5", @stage.call("-3.5")
  end

  def test_non_foldable_op_unchanged
    assert_equal "2<=>3", @stage.call("2<=>3")
  end

  def test_mixed_int_float_arithmetic
    assert_equal "2.5", @stage.call("5/2.0")
  end

  def test_large_power_producing_infinity_not_folded
    # 2.0**10000 = Infinity → should not fold
    assert_equal "2.0**10000", @stage.call("2.0**10000")
  end

  def test_fold_in_context
    assert_equal "x=256", @stage.call("x=1<<8")
  end

  def test_negative_result
    assert_equal "-7", @stage.call("3-10")
  end

  def test_unary_minus_on_expression
    assert_equal "-5", @stage.call("-(2+3)")
  end

  def test_unary_minus_on_non_numeric
    assert_equal "-(x)", @stage.call("-(x)")
  end

  def test_result_longer_than_original_not_folded
    assert_equal "9**9", @stage.call("9**9")
  end

  def test_nested_parentheses
    assert_equal "((7))", @stage.call("((3+4))")
  end
end
