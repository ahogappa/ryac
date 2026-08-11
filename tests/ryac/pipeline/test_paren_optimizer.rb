# frozen_string_literal: true

require_relative '../../test_helper'

class TestParenOptimizer < Minitest::Test
  def optimize(source)
    Ryac::Pipeline::ParenOptimizer.new.call(source)
  end

  # Receiver-less calls (existing behavior)

  def test_receiver_less_at_statement_level
    assert_equal 'puts 1', optimize('puts(1)')
  end

  # Receiver-ful calls at statement level (new behavior)

  def test_receiver_ful_at_statement_level
    assert_equal 'obj.foo 1', optimize('obj.foo(1)')
  end

  def test_ivar_receiver_at_statement_level
    assert_equal '@history.push amount', optimize('@history.push(amount)')
  end

  def test_receiver_ful_multiple_args
    assert_equal 'obj.foo 1, 2, 3', optimize('obj.foo(1, 2, 3)')
  end

  def test_receiver_ful_keyword_args
    assert_equal 'calc.add_number 5,verbose:true', optimize('calc.add_number(5,verbose:true)')
  end

  # Receiver-ful calls that must keep parens

  def test_receiver_ful_in_chain_keeps_parens
    assert_equal 'obj.foo(1).bar', optimize('obj.foo(1).bar')
  end

  def test_receiver_ful_as_argument_keeps_parens
    assert_equal 'puts obj.foo(1)', optimize('puts(obj.foo(1))')
  end

  def test_receiver_ful_with_block_keeps_parens
    assert_equal 'obj.foo(1) { }', optimize('obj.foo(1) { }')
  end

  def test_receiver_ful_no_args_keeps_parens
    assert_equal 'obj.foo()', optimize('obj.foo()')
  end

  def test_receiver_ful_predicate_keeps_parens
    assert_equal 'obj.include?(1)', optimize('obj.include?(1)')
  end

  # Block in arguments — parens must be kept to prevent block re-attachment

  def test_arg_with_block_keeps_parens
    assert_equal 'foo(bar { })', optimize('foo(bar { })')
  end

  def test_arg_chain_with_block_keeps_parens
    assert_equal 'foo(bar.map { |x| x }.first)', optimize('foo(bar.map { |x| x }.first)')
  end

  def test_receiver_ful_arg_with_block_keeps_parens
    assert_equal 'obj.foo(bar.map { |x| x })', optimize('obj.foo(bar.map { |x| x })')
  end

  def test_arg_block_inside_parens_allows_removal
    assert_equal 'foo bar(baz { })', optimize('foo(bar(baz { }))')
  end

  # Yield paren removal

  def test_yield_parens_removed
    assert_equal 'def f;yield 1;end', optimize('def f;yield(1);end')
  end

  def test_yield_no_args_keeps_parens
    assert_equal 'def f;yield();end', optimize('def f;yield();end')
  end

  # Keyword args with modifier context — parens must be kept

  def test_keyword_args_with_modifier_if_keeps_parens
    assert_equal 'foo(x, a: 1) if cond', optimize('foo(x, a: 1) if cond')
  end

  def test_keyword_args_with_modifier_unless_keeps_parens
    assert_equal 'foo(x, a: 1) unless cond', optimize('foo(x, a: 1) unless cond')
  end

  def test_keyword_args_without_modifier_removes_parens
    assert_equal "foo x, a: 1", optimize('foo(x, a: 1)')
  end

  # Statement-level propagation through control structures

  def test_call_inside_if_body
    assert_equal 'if true;puts 1;end', optimize('if true;puts(1);end')
  end

  def test_call_inside_if_else
    assert_equal 'if true;puts 1;else;puts 2;end', optimize('if true;puts(1);else;puts(2);end')
  end

  def test_call_inside_unless_body
    assert_equal 'unless false;puts 1;end', optimize('unless false;puts(1);end')
  end

  def test_call_inside_while_body
    assert_equal 'while true;puts 1;end', optimize('while true;puts(1);end')
  end

  def test_call_inside_def_body
    assert_equal 'def f;puts 1;end', optimize('def f;puts(1);end')
  end

  def test_call_inside_class_body
    assert_equal 'class C;puts 1;end', optimize('class C;puts(1);end')
  end

  def test_call_inside_begin_rescue_ensure
    assert_equal 'begin;puts 1;rescue;puts 2;ensure;puts 3;end',
                 optimize('begin;puts(1);rescue;puts(2);ensure;puts(3);end')
  end

  def test_call_inside_case_when
    assert_equal 'case x;when 1;puts 1;end', optimize('case x;when 1;puts(1);end')
  end

  def test_call_inside_block
    assert_equal '[].each{puts 1}', optimize('[].each{puts(1)}')
  end

  def test_call_inside_for
    assert_equal 'for i in [1];puts i;end', optimize('for i in [1];puts(i);end')
  end

  # Pattern matching (case...in) — CaseMatchNode + InNode

  def test_call_inside_case_in
    assert_equal 'case x;in 1;puts 1;else;puts 2;end',
                 optimize('case x;in 1;puts(1);else;puts(2);end')
  end

  # END block — PostExecutionNode

  def test_call_inside_end_block
    assert_equal 'END{puts 1}', optimize('END{puts(1)}')
  end

  # Block argument (&block) — non-BlockNode block child

  def test_call_with_block_argument
    assert_equal 'foo(bar, &baz)', optimize('foo(bar, &baz)')
  end

  def test_call_inside_until_body
    assert_equal 'until false;puts 1;end', optimize('until false;puts(1);end')
  end

  def test_call_inside_module_body
    assert_equal 'module M;puts 1;end', optimize('module M;puts(1);end')
  end

  def test_call_inside_lambda_body
    assert_equal '->(){ puts 1 }.call', optimize('->(){ puts(1) }.call')
  end

  def test_call_inside_parentheses
    assert_equal '(puts 1)', optimize('(puts(1))')
  end

  def test_call_in_local_variable_write
    assert_equal 'x = puts 1', optimize('x = puts(1)')
  end

  # Ternary — arms are NOT at statement level

  def test_ternary_keeps_parens
    assert_equal 'x = true ? puts(1) : puts(2)', optimize('x = true ? puts(1) : puts(2)')
  end
end
