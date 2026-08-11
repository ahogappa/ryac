# frozen_string_literal: true

require_relative '../../test_helper'

class TestEndlessMethod < Minitest::Test
  def setup
    @stage = Ryac::Pipeline::EndlessMethod.new
  end

  def test_simple_def_to_endless
    assert_equal "def foo =bar", @stage.call("def foo;bar;end")
  end

  def test_def_with_args
    assert_equal "def foo(x) =x+1", @stage.call("def foo(x);x+1;end")
  end

  def test_multi_statement_wrapped_in_parens
    assert_equal "def foo =(bar;baz)", @stage.call("def foo;bar;baz;end")
  end

  def test_setter_not_converted
    assert_equal "def foo=(x);@x=x;end", @stage.call("def foo=(x);@x=x;end")
  end

  def test_modifier_if_body_wrapped_in_parens
    assert_equal "def foo =(bar if x)", @stage.call("def foo;bar if x;end")
  end

  def test_nested_def
    result = @stage.call("def outer;def inner;42;end;end")
    assert_equal "def outer =def inner =42", result
  end

  def test_multi_write_not_converted
    assert_equal "def foo;a,b=1,2;end", @stage.call("def foo;a,b=1,2;end")
  end

  def test_body_with_semicolon_wrapped_in_parens
    assert_equal "def foo =(a;b)", @stage.call("def foo;a;b;end")
  end

  def test_self_method
    assert_equal "def self.foo =bar", @stage.call("def self.foo;bar;end")
  end

  def test_modifier_unless_body_wrapped_in_parens
    assert_equal "def foo =(bar unless x)", @stage.call("def foo;bar unless x;end")
  end

  def test_modifier_while_body_wrapped_in_parens
    assert_equal "def foo =(bar while x)", @stage.call("def foo;bar while x;end")
  end

  def test_empty_body_not_converted
    assert_equal "def foo;end", @stage.call("def foo;end")
  end

  def test_and_body_wrapped_in_parens
    # and has lower precedence than = in endless methods
    assert_equal "def foo =(a and b)", @stage.call("def foo;a and b;end")
  end

  def test_or_body_wrapped_in_parens
    assert_equal "def foo =(a or b)", @stage.call("def foo;a or b;end")
  end

  def test_double_ampersand_not_wrapped
    assert_equal "def foo =a&&b", @stage.call("def foo;a&&b;end")
  end

  def test_double_pipe_not_wrapped
    assert_equal "def foo =a||b", @stage.call("def foo;a||b;end")
  end

  def test_modifier_until_body_wrapped_in_parens
    assert_equal "def foo =(bar until x)", @stage.call("def foo;bar until x;end")
  end
end
