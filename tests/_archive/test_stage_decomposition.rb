# frozen_string_literal: true

require_relative 'test_helper'

class TestBooleanShorten < Minitest::Test
  def shorten(code)
    Ryac::Pipeline::BooleanShorten.new.call(code)
  end

  def test_true_to_bang_bang
    assert_equal 'x=!!1', shorten('x=true')
  end

  def test_false_to_bang
    assert_equal 'x=!1', shorten('x=false')
  end

  def test_preserves_non_boolean
    code = 'x=42;puts(x)'
    assert_equal code, shorten(code)
  end
end

class TestCharShorten < Minitest::Test
  def shorten(code)
    Ryac::Pipeline::CharShorten.new.call(code)
  end

  def test_single_char_string
    assert_equal 'x=?a', shorten('x="a"')
  end

  def test_single_digit_string
    assert_equal 'x=?1', shorten('x="1"')
  end

  def test_multi_char_string_unchanged
    assert_equal 'x="ab"', shorten('x="ab"')
  end

  def test_preserves_single_quoted
    # ?a form is only valid for double-quoted or unquoted strings
    # Prism StringNode with opening "'" should not be converted
    code = "x='a'"
    result = shorten(code)
    # Single-quoted 'a' has opening_loc, so it should be convertible
    assert_equal 'x=?a', result
  end
end

class TestConstantFold < Minitest::Test
  def fold(code)
    Ryac::Pipeline::ConstantFold.new.call(code)
  end

  def test_simple_multiplication
    assert_equal 'x=86400', fold('x=24*60*60')
  end

  def test_addition
    assert_equal 'x=10', fold('x=3+7')
  end

  def test_no_fold_when_longer
    # 999*999 = 998001 (6 chars) vs 999*999 (7 chars) — fold is shorter
    assert_equal 'x=998001', fold('x=999*999')
  end

  def test_preserves_non_foldable
    code = 'x=a+b'
    assert_equal code, fold(code)
  end
end

class TestControlFlowSimplify < Minitest::Test
  def simplify(code)
    Ryac::Pipeline::ControlFlowSimplify.new.call(code)
  end

  def test_if_else_to_ternary
    assert_equal 'x ? 1:0', simplify('if x;1;else;0;end')
  end

  def test_if_to_modifier
    assert_equal 'puts(1) if x', simplify('if x;puts(1);end')
  end

  def test_while_to_modifier
    assert_equal 'x-=1 while x>0', simplify('while x>0;x-=1;end')
  end

  def test_preserves_multi_statement_if
    code = 'if x;puts(1);puts(2);end'
    assert_equal code, simplify(code)
  end
end

class TestEndlessMethod < Minitest::Test
  def endless(code)
    Ryac::Pipeline::EndlessMethod.new.call(code)
  end

  def test_def_to_endless
    assert_equal 'def foo =1', endless('def foo;1;end')
  end

  def test_preserves_multi_statement_def
    code = 'def foo;puts(1);2;end'
    assert_equal code, endless(code)
  end
end
