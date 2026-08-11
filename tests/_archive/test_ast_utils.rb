# frozen_string_literal: true

require_relative 'test_helper'

class TestAstUtils < Minitest::Test
  # Test that AstUtils functions work correctly on Prism AST nodes.
  # These are pure functions extracted from rebuild_nodes.rb.

  def parse_expr(code)
    Prism.parse(code).value.statements.body.first
  end

  # --- unwrap_statements ---

  def test_unwrap_statements_returns_inner_node_from_single_statement
    node = Prism.parse("x = 1; (x)").value.statements.body.last
    result = Ryac::AstUtils.unwrap_statements(node)
    assert_instance_of Prism::LocalVariableReadNode, result
  end

  def test_unwrap_statements_returns_node_for_multi_statement
    node = Prism.parse("(x;y)").value.statements.body.first
    result = Ryac::AstUtils.unwrap_statements(node)
    assert_instance_of Prism::StatementsNode, result
  end

  def test_unwrap_statements_returns_nil_for_nil
    assert_nil Ryac::AstUtils.unwrap_statements(nil)
  end

  # --- middle_method? ---

  def test_middle_method_true_for_operators
    %i[+ - * / ** % ^ > < <= >= <=> == === != & | << >> =~ !~].each do |op|
      assert Ryac::AstUtils.middle_method?(op), "Expected #{op} to be a middle method"
    end
  end

  def test_middle_method_false_for_regular_methods
    %i[puts print foo bar].each do |name|
      refute Ryac::AstUtils.middle_method?(name), "Expected #{name} NOT to be a middle method"
    end
  end

  # --- logical_op? ---

  def test_logical_op_true_for_and_or
    and_node = parse_expr("a && b")
    or_node = parse_expr("a || b")
    assert Ryac::AstUtils.logical_op?(and_node)
    assert Ryac::AstUtils.logical_op?(or_node)
  end

  def test_logical_op_false_for_other_nodes
    node = parse_expr("1 + 2")
    refute Ryac::AstUtils.logical_op?(node)
  end

  # --- has_block? ---

  def test_has_block_true_when_block_present
    node = parse_expr("foo { 1 }")
    assert Ryac::AstUtils.has_block?(node)
  end

  def test_has_block_false_when_no_block
    node = parse_expr("foo(1)")
    refute Ryac::AstUtils.has_block?(node)
  end

  # --- single_statement_body? ---

  def test_single_statement_body_true_for_single
    node = parse_expr("if true; 1; end")
    assert Ryac::AstUtils.single_statement_body?(node.statements)
  end

  def test_single_statement_body_false_for_multi
    node = parse_expr("if true; 1; 2; end")
    refute Ryac::AstUtils.single_statement_body?(node.statements)
  end

  def test_single_statement_body_false_for_nil
    refute Ryac::AstUtils.single_statement_body?(nil)
  end

  # --- setter_def_name? ---

  def test_setter_def_name_true_for_setter
    assert Ryac::AstUtils.setter_def_name?(:foo=)
    assert Ryac::AstUtils.setter_def_name?("name=")
  end

  def test_setter_def_name_false_for_comparison
    %w[== != <= >= ===].each do |op|
      refute Ryac::AstUtils.setter_def_name?(op), "Expected #{op} NOT to be a setter"
    end
  end

  def test_setter_def_name_false_for_regular
    refute Ryac::AstUtils.setter_def_name?(:foo)
  end

  # --- simple_negatable? ---

  def test_simple_negatable_false_for_logical_op
    node = parse_expr("a || b")
    refute Ryac::AstUtils.simple_negatable?(node)
  end

  def test_simple_negatable_false_for_middle_method_call
    node = parse_expr("a + b")
    refute Ryac::AstUtils.simple_negatable?(node)
  end

  def test_simple_negatable_true_for_method_call
    node = parse_expr("foo(1)")
    assert Ryac::AstUtils.simple_negatable?(node)
  end

  # --- can_omit_parens? ---

  def test_can_omit_parens_true_for_simple_call
    node = parse_expr("puts(1)")
    assert Ryac::AstUtils.can_omit_parens?(node)
  end

  def test_can_omit_parens_false_with_receiver
    node = parse_expr("obj.foo(1)")
    refute Ryac::AstUtils.can_omit_parens?(node)
  end

  def test_can_omit_parens_false_with_block
    node = parse_expr("foo(1) { 2 }")
    refute Ryac::AstUtils.can_omit_parens?(node)
  end

  def test_can_omit_parens_false_no_args
    node = parse_expr("foo()")
    refute Ryac::AstUtils.can_omit_parens?(node)
  end

  def test_can_omit_parens_false_for_predicate
    node = parse_expr("empty?(x)")
    refute Ryac::AstUtils.can_omit_parens?(node)
  end

  def test_can_omit_parens_false_when_first_arg_is_hash
    node = parse_expr("foo({a: 1})")
    refute Ryac::AstUtils.can_omit_parens?(node)
  end

  def test_can_omit_parens_false_for_forwarding_args
    node = Prism.parse("def g(...);e(...);end").value.statements.body[0].body.body[0]
    refute Ryac::AstUtils.can_omit_parens?(node)
  end

  # --- first_arg_starts_with_brace? ---

  def test_first_arg_starts_with_brace_true_for_hash
    node = parse_expr("{a: 1}")
    assert Ryac::AstUtils.first_arg_starts_with_brace?(node)
  end

  def test_first_arg_starts_with_brace_false_for_non_hash
    node = parse_expr("1")
    refute Ryac::AstUtils.first_arg_starts_with_brace?(node)
  end
end
