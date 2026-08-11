# frozen_string_literal: true

require_relative 'test_helper'

class TestParenthesisRemoval < Minitest::Test
  def optimize(source)
    Ryac::Pipeline::ParenOptimizer.new.call(source)
  end

  # === Removal cases (statement_level = true) ===

  def test_removes_parens_at_top_level
    assert_equal "puts x", optimize("puts(x)")
  end

  def test_removes_parens_multi_arg
    assert_equal "puts x,y", optimize("puts(x,y)")
  end

  def test_removes_parens_multiple_statements
    assert_equal "puts x;puts y", optimize("puts(x);puts(y)")
  end

  def test_removes_parens_in_if_body
    assert_equal "if cond;puts x;end", optimize("if cond;puts(x);end")
  end

  def test_removes_parens_in_else_body
    assert_equal "if c;puts x;else;puts y;end", optimize("if c;puts(x);else;puts(y);end")
  end

  def test_removes_parens_in_def_body
    assert_equal "def m;puts x;end", optimize("def m;puts(x);end")
  end

  def test_removes_parens_modifier_if
    assert_equal "puts x if cond", optimize("puts(x) if cond")
  end

  def test_removes_parens_in_while_body
    assert_equal "while cond;puts x;end", optimize("while cond;puts(x);end")
  end

  def test_removes_parens_in_class_body
    assert_equal "class C;puts x;end", optimize("class C;puts(x);end")
  end

  def test_removes_parens_in_block_body
    assert_equal "[1].each{|x|puts x}", optimize("[1].each{|x|puts(x)}")
  end

  def test_removes_parens_in_local_var_write
    assert_equal "x=puts y", optimize("x=puts(y)")
  end

  def test_removes_yield_parens
    assert_equal "def m;yield 1;end", optimize("def m;yield(1);end")
  end

  def test_outer_removes_inner_keeps
    assert_equal "puts method(x)", optimize("puts(method(x))")
  end

  # === Preservation cases (must NOT remove) ===

  def test_keeps_parens_with_receiver
    assert_equal "obj.method(x)", optimize("obj.method(x)")
  end

  def test_keeps_parens_no_args
    assert_equal "puts()", optimize("puts()")
  end

  def test_keeps_parens_predicate_method
    assert_equal "include?(x)", optimize("include?(x)")
  end

  def test_keeps_parens_hash_first_arg
    assert_equal "method({a:1})", optimize("method({a:1})")
  end

  def test_keeps_parens_in_ternary_arms
    assert_equal "x ?puts(1):puts(2)", optimize("x ?puts(1):puts(2)")
  end

  def test_keeps_parens_keyword_args_modifier_if
    assert_equal "foo(x,a:1) if cond", optimize("foo(x,a:1) if cond")
  end

  def test_keeps_parens_keyword_args_modifier_unless
    assert_equal "foo(x,a:1) unless cond", optimize("foo(x,a:1) unless cond")
  end

  def test_keeps_parens_keyword_args_modifier_while
    assert_equal "foo(x,a:1) while cond", optimize("foo(x,a:1) while cond")
  end

  def test_keeps_parens_keyword_args_modifier_until
    assert_equal "foo(x,a:1) until cond", optimize("foo(x,a:1) until cond")
  end

  def test_removes_parens_keyword_args_in_block_if
    assert_equal "if cond;foo x,a:1;end", optimize("if cond;foo(x,a:1);end")
  end

  def test_keeps_yield_parens_in_non_statement_context
    assert_equal "x ?yield(1):yield(2)", optimize("x ?yield(1):yield(2)")
  end

  # === Edge cases ===

  def test_idempotent
    source = "puts(x);obj.method(y);if cond;foo(z);end"
    once = optimize(source)
    twice = optimize(once)
    assert_equal once, twice
  end

  def test_preserves_clean_code
    source = "puts x;foo y,z"
    assert_equal source, optimize(source)
  end
end
