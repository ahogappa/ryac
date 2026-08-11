# frozen_string_literal: true

require_relative 'test_helper'

class TestParenOptimizer < Minitest::Test
  def optimize(source)
    Ryac::Pipeline::ParenOptimizer.new.call(source)
  end

  # === Statement-level paren removal ===

  def test_removes_parens_at_top_level
    assert_equal "puts x", optimize("puts(x)")
  end

  def test_removes_parens_multi_arg
    assert_equal "puts x,y", optimize("puts(x,y)")
  end

  def test_removes_parens_multiple_statements
    assert_equal "puts x;puts y", optimize("puts(x);puts(y)")
  end

  # === Parens kept when can_omit_parens? returns false ===

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

  def test_keeps_parens_with_block
    assert_equal "[1].map{|x|x}", optimize("[1].map{|x|x}")
  end

  # === Statement-level contexts ===

  def test_removes_parens_in_if_body
    assert_equal "if cond;puts x;end", optimize("if cond;puts(x);end")
  end

  def test_removes_parens_in_else_body
    assert_equal "if cond;puts x;else;puts y;end", optimize("if cond;puts(x);else;puts(y);end")
  end

  def test_removes_parens_in_def_body
    assert_equal "def m;puts x;end", optimize("def m;puts(x);end")
  end

  def test_removes_parens_modifier_if_body
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

  # === Modifier context: keep parens when keyword args present ===

  def test_keeps_parens_with_keyword_args_in_modifier_if
    assert_equal "foo(x,a:1) if cond", optimize("foo(x,a:1) if cond")
  end

  def test_keeps_parens_with_keyword_args_in_modifier_unless
    assert_equal "foo(x,a:1) unless cond", optimize("foo(x,a:1) unless cond")
  end

  def test_keeps_parens_with_keyword_args_in_modifier_while
    assert_equal "foo(x,a:1) while cond", optimize("foo(x,a:1) while cond")
  end

  def test_keeps_parens_with_keyword_args_in_modifier_until
    assert_equal "foo(x,a:1) until cond", optimize("foo(x,a:1) until cond")
  end

  def test_removes_parens_without_keyword_args_in_modifier_if
    assert_equal "puts x if cond", optimize("puts(x) if cond")
  end

  def test_removes_parens_with_keyword_args_in_block_if
    assert_equal "if cond;foo x,a:1;end", optimize("if cond;foo(x,a:1);end")
  end

  # === Ternary arms are NOT statement level ===

  def test_keeps_parens_in_ternary_arms
    assert_equal "x ?puts(1):puts(2)", optimize("x ?puts(1):puts(2)")
  end

  # === Yield paren removal ===

  def test_removes_yield_parens_at_statement_level
    assert_equal "def m;yield 1;end", optimize("def m;yield(1);end")
  end

  def test_keeps_yield_parens_in_non_statement_context
    assert_equal "x ?yield(1):yield(2)", optimize("x ?yield(1):yield(2)")
  end

  # === Local variable write inherits statement level ===

  def test_removes_parens_in_local_var_write_value
    assert_equal "x=puts y", optimize("x=puts(y)")
  end

  # === Nested calls ===

  def test_outer_removes_inner_keeps
    assert_equal "puts method(x)", optimize("puts(method(x))")
  end

  # === Endless def body ===

  def test_removes_parens_in_endless_def_body
    assert_equal "def m =puts x", optimize("def m =puts(x)")
  end

  # === Integration: Compactor → SyntaxOptimizer → ParenOptimizer ===

  def test_full_pipeline_through_paren_optimizer
    code = <<~RUBY
      x = true
      y = false
      puts(x, y)

      def my_method(my_arg)
        if my_arg
          "hello"
        else
          "world"
        end
      end
      puts my_method("a")
    RUBY
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: code, file_boundaries: [], original_size: code.bytesize, stdlib_requires: []
    )
    preprocessed = Ryac::Pipeline::Preprocessor.new.call(source)
    compacted = Ryac::Pipeline::Compactor.new.call(preprocessed.content)
    syntax_optimized = Ryac::Minifier::OPTIMIZE[0...-1].reduce(compacted) { |r, k| k.new.call(r) }
    result = optimize(syntax_optimized)
    assert_equal "x=!!1;y=!1;puts x,y;def my_method(my_arg) =my_arg ? \"hello\":\"world\";puts my_method(?a)", result
  end
end
