# frozen_string_literal: true

require_relative 'test_helper'

class TestSyntaxOptimizerRewrite < Minitest::Test
  include MinifyTestHelper

  def compact(code)
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: code,
      file_boundaries: [],
      original_size: code.bytesize,
      stdlib_requires: []
    )
    preprocessed = Ryac::Pipeline::Preprocessor.new.call(source)
    Ryac::Pipeline::Compactor.new.call(preprocessed.content)
  end

  def optimize(compacted)
    Ryac::Minifier::OPTIMIZE[0...-1].reduce(compacted) { |r, k| k.new.call(r) }
  end

  # --- Leaf transforms ---

  def setup_leaves
    @leaves ||= optimize(compact(<<~RUBY))
      x = true
      y = false
      puts(x, y)
    RUBY
  end

  def test_true_becomes_double_bang
    setup_leaves
    assert_equal "x=!!1;y=!1;puts(x,y)", @leaves
  end

  def test_single_char_string
    result = optimize(compact('puts("a")'))
    assert_equal "puts(?a)", result
  end

  def test_multi_char_string_unchanged
    result = optimize(compact('puts("ab")'))
    assert_equal 'puts("ab")', result
  end

  # --- If/ternary ---

  def setup_if_ternary
    @if_ternary ||= optimize(compact(<<~RUBY))
      def my_method(my_arg)
        if my_arg
          "hello"
        else
          "world"
        end
      end
      puts(my_method("a"))
    RUBY
  end

  def test_if_else_becomes_ternary
    setup_if_ternary
    assert_equal 'def my_method(my_arg) =my_arg ? "hello":"world";puts(my_method(?a))', @if_ternary
  end

  # --- Modifier if ---

  def test_modifier_if
    result = optimize(compact(<<~RUBY))
      if x
        puts(1)
      end
    RUBY
    assert_equal "puts(1) if x", result
  end

  # --- While modifier ---

  def test_modifier_while
    result = optimize(compact(<<~RUBY))
      while x
        puts(1)
      end
    RUBY
    assert_equal "puts(1) while x", result
  end

  # --- Until modifier ---

  def test_modifier_until
    result = optimize(compact(<<~RUBY))
      until x
        puts(1)
      end
    RUBY
    assert_equal "puts(1) until x", result
  end

  # --- Endless method ---

  def test_endless_method
    result = optimize(compact(<<~RUBY))
      def foo(x)
        x + 1
      end
    RUBY
    assert_equal "def foo(x) =x+1", result
  end

  def test_endless_method_with_if_modifier
    # `def foo =bar if cond` parses as `(def foo =bar) if cond`
    # which conditionally defines the method — semantics change.
    # Must NOT convert to endless form when body is an if/unless modifier.
    result = optimize(compact(<<~RUBY))
      def foo
        bar if cond
      end
    RUBY
    assert_equal "def foo;bar if cond;end", result
  end

  def test_endless_method_with_unless_modifier
    result = optimize(compact(<<~RUBY))
      def foo
        bar unless cond
      end
    RUBY
    assert_equal "def foo;bar if !cond;end", result
  end

  def test_endless_method_not_multi_assign
    result = optimize(compact(<<~RUBY))
      def initialize(width, format)
        @width, @format, @list = width, format, []
      end
    RUBY
    assert_equal "def initialize(width,format);@width,@format,@list=width,format,[];end", result
  end

  def test_setter_not_endless
    result = optimize(compact(<<~RUBY))
      def foo=(x)
        @x = x
      end
    RUBY
    assert_equal "def foo=(x);@x=x;end", result
  end

  # --- Unless ---

  def test_unless_simple
    result = optimize(compact(<<~RUBY))
      unless done
        puts(1)
      end
    RUBY
    assert_equal "puts(1) if !done", result
  end

  # --- Ternary in expression context needs parens ---

  def test_ternary_after_shovel_operator
    result = optimize('d<<if f;bar;else;baz;end')
    assert_equal 'd<<(f ? bar : baz)', result
  end

  def test_ternary_at_statement_level_no_parens
    result = optimize('if f;bar;else;baz;end')
    assert_equal 'f ? bar : baz', result
  end

  def test_ternary_after_block_params_no_parens
    result = optimize('x.map{|a|if a;"yes";else;"no";end}')
    assert_equal 'x.map{|a|a ? "yes":"no"}', result
  end

  def test_ternary_after_assignment_no_parens
    result = optimize('x=if f;bar;else;baz;end')
    assert_equal 'x=f ? bar : baz', result
  end

  # --- Multi-statement body stays as block ---

  def test_if_multi_statement_stays_block
    result = optimize(compact(<<~RUBY))
      if x
        puts(1)
        puts(2)
      end
    RUBY
    assert_equal "if x;puts(1);puts(2);end", result
  end

  def test_while_multi_statement_stays_block
    result = optimize(compact(<<~RUBY))
      while x
        puts(1)
        puts(2)
      end
    RUBY
    assert_equal "while x;puts(1);puts(2);end", result
  end

  # --- Endless method: multi-statement stays normal ---

  def test_def_multi_statement_stays_normal
    result = optimize(compact(<<~RUBY))
      def foo(x)
        y = x + 1
        y * 2
      end
    RUBY
    assert_equal "def foo(x);y=x+1;y*2;end", result
  end

  # --- Constant folding ---

  def test_constant_fold_addition
    assert_equal "x=3", optimize("x=1+2")
  end

  def test_constant_fold_chained_multiplication
    assert_equal "x=86400", optimize("x=24*60*60")
  end

  def test_constant_fold_subtraction
    assert_equal "x=7", optimize("x=10-3")
  end

  def test_constant_fold_division
    assert_equal "x=5", optimize("x=10/2")
  end

  def test_constant_fold_modulo
    assert_equal "x=1", optimize("x=10%3")
  end

  def test_constant_fold_power
    assert_equal "x=1024", optimize("x=2**10")
  end

  def test_constant_fold_skips_when_result_longer
    assert_equal "x=2**100", optimize("x=2**100")
  end

  def test_constant_fold_no_division_by_zero
    assert_equal "x=1/0", optimize("x=1/0")
  end

  def test_constant_fold_no_modulo_by_zero
    assert_equal "x=1%0", optimize("x=1%0")
  end

  def test_constant_fold_skips_variables
    assert_equal "x=y+1", optimize("x=y+1")
  end

  def test_constant_fold_negative_result
    assert_equal "x=-4", optimize("x=1-5")
  end

  def test_constant_fold_float
    assert_equal "x=4.0", optimize("x=1.5+2.5")
  end

  def test_constant_fold_with_parens
    assert_equal "x=9", optimize("x=(1+2)*3")
  end

  def test_constant_fold_bitshift
    assert_equal "x=256", optimize("x=1<<8")
  end

  def test_constant_fold_through_compact
    result = optimize(compact(<<~RUBY))
      SECONDS_PER_DAY = 24 * 60 * 60
      puts(SECONDS_PER_DAY)
    RUBY
    assert_equal "SECONDS_PER_DAY=86400;puts(SECONDS_PER_DAY)", result
  end

  def test_ternary_with_multibyte_condition
    result = optimize("if 変数;1;else;0;end")
    assert_equal "変数 ? 1:0", result
  end
end
