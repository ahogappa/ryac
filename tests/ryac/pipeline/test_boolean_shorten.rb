# frozen_string_literal: true

require_relative '../../test_helper'

class TestBooleanShorten < Minitest::Test
  def setup
    @stage = Ryac::Pipeline::BooleanShorten.new
  end

  def test_true_to_double_bang
    assert_equal "!!1", @stage.call("true")
  end

  def test_false_to_bang
    assert_equal "!1", @stage.call("false")
  end

  def test_true_in_expression
    assert_equal "x=!!1", @stage.call("x=true")
  end

  def test_false_in_expression
    assert_equal "x=!1", @stage.call("x=false")
  end

  def test_multiple_booleans
    assert_equal "!!1&&!1", @stage.call("true&&false")
  end

  def test_no_booleans_unchanged
    assert_equal "x+y", @stage.call("x+y")
  end

  def test_block_param_default_true_preserved
    # `|all=!!1|` is ambiguous — parser sees `|` as OR, not block param delimiter
    assert_equal "foo{|all=true|puts all}", @stage.call("foo{|all=true|puts all}")
  end

  def test_block_param_default_false_preserved
    assert_equal "foo{|flag=false|puts flag}", @stage.call("foo{|flag=false|puts flag}")
  end

  def test_def_param_default_still_shortened
    # def params use parens, so no ambiguity with `|`
    assert_equal "def foo(all=!!1);end", @stage.call("def foo(all=true);end")
  end

end
