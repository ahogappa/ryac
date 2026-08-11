# frozen_string_literal: true

require_relative '../test_helper'

class TestAstUtils < Minitest::Test
  def test_middle_method_includes_arithmetic
    %i[+ - * / ** %].each do |op|
      assert Ryac::AstUtils.middle_method?(op), "#{op} should be a middle method"
    end
  end

  def test_middle_method_includes_comparison
    %i[> < <= >= <=> == === != =~ !~].each do |op|
      assert Ryac::AstUtils.middle_method?(op), "#{op} should be a middle method"
    end
  end

  def test_middle_method_includes_bitwise
    %i[& | ^ << >>].each do |op|
      assert Ryac::AstUtils.middle_method?(op), "#{op} should be a middle method"
    end
  end

  def test_middle_method_rejects_non_operators
    %i[foo bar to_s puts each].each do |name|
      refute Ryac::AstUtils.middle_method?(name), "#{name} should not be a middle method"
    end
  end

  def test_setter_def_name_true
    assert Ryac::AstUtils.setter_def_name?(:foo=)
    assert Ryac::AstUtils.setter_def_name?(:name=)
  end

  def test_setter_def_name_false_for_comparison_operators
    %w[== != <= >= ===].each do |op|
      refute Ryac::AstUtils.setter_def_name?(op.to_sym), "#{op} should not be a setter"
    end
  end

  def test_setter_def_name_false_for_regular_methods
    refute Ryac::AstUtils.setter_def_name?(:foo)
    refute Ryac::AstUtils.setter_def_name?(:bar?)
  end

  def test_single_statement_body_nil
    refute Ryac::AstUtils.single_statement_body?(nil)
  end

  def test_single_statement_body_one_statement
    node = Prism.parse("1").value.statements
    assert Ryac::AstUtils.single_statement_body?(node)
  end

  def test_single_statement_body_multiple
    node = Prism.parse("1;2").value.statements
    refute Ryac::AstUtils.single_statement_body?(node)
  end

  def test_modifier_control_flow_if
    ast = Prism.parse("x if y").value.statements.body.first
    assert Ryac::AstUtils.modifier_control_flow?(ast)
  end

  def test_modifier_control_flow_block_if
    ast = Prism.parse("if y;x;end").value.statements.body.first
    refute Ryac::AstUtils.modifier_control_flow?(ast)
  end

  def test_modifier_control_flow_unless
    ast = Prism.parse("x unless y").value.statements.body.first
    assert Ryac::AstUtils.modifier_control_flow?(ast)
  end

  def test_modifier_control_flow_while
    ast = Prism.parse("x while y").value.statements.body.first
    assert Ryac::AstUtils.modifier_control_flow?(ast)
  end

  def test_modifier_control_flow_until
    ast = Prism.parse("x until y").value.statements.body.first
    assert Ryac::AstUtils.modifier_control_flow?(ast)
  end

  def test_modifier_control_flow_other_nodes
    ast = Prism.parse("x + y").value.statements.body.first
    refute Ryac::AstUtils.modifier_control_flow?(ast)
  end

  def test_logical_op_or
    ast = Prism.parse("a || b").value.statements.body.first
    assert Ryac::AstUtils.logical_op?(ast)
  end

  def test_logical_op_and
    ast = Prism.parse("a && b").value.statements.body.first
    assert Ryac::AstUtils.logical_op?(ast)
  end

  def test_logical_op_other
    ast = Prism.parse("a + b").value.statements.body.first
    refute Ryac::AstUtils.logical_op?(ast)
  end

  def test_ternary_needs_parens_at_start
    source = "x?1:2"
    ast = Prism.parse(source).value.statements.body.first
    refute Ryac::AstUtils.ternary_needs_parens?(ast, source)
  end

  def test_ternary_needs_parens_after_semicolon
    source = "z=1;z ?1:2"
    ast = Prism.parse(source).value.statements.body[1]
    refute Ryac::AstUtils.ternary_needs_parens?(ast, source)
  end

  def test_ternary_needs_parens_after_equals
    source = "z=1;a=z ?1:2"
    ast = Prism.parse(source).value.statements.body[1]
    ternary = ast.value
    refute Ryac::AstUtils.ternary_needs_parens?(ternary, source)
  end

  def test_can_omit_parens_no_receiver_with_args
    ast = Prism.parse("puts(1)").value.statements.body.first
    assert Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_with_receiver
    ast = Prism.parse("foo.bar(1)").value.statements.body.first
    assert Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_with_ivar_receiver
    ast = Prism.parse("@history.push(1)").value.statements.body.first
    assert Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_with_receiver_and_block
    ast = Prism.parse("foo.bar(1) { }").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_with_receiver_no_args
    ast = Prism.parse("foo.bar()").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_with_receiver_predicate
    ast = Prism.parse("foo.include?(1)").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_without_args
    ast = Prism.parse("puts()").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_with_block
    ast = Prism.parse("foo(1) { }").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_for_predicate_method
    ast = Prism.parse("include?(1)").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_when_first_arg_is_hash
    ast = Prism.parse("foo({a: 1})").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_when_arg_has_block
    ast = Prism.parse("foo(bar { })").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_when_arg_chain_has_block
    ast = Prism.parse("foo(bar.map { |x| x }.first)").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_when_receiver_arg_has_block
    ast = Prism.parse("obj.foo(bar.map { |x| x })").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_true_when_arg_block_inside_parens
    ast = Prism.parse("foo(bar(baz { }))").value.statements.body.first
    assert Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_for_index_access
    ast = Prism.parse("obj[1]").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_for_index_assignment
    ast = Prism.parse("obj[1] = 2").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_for_forwarding_args
    ast = Prism.parse("def foo(...);bar(...);end").value.statements.body.first
    call = ast.body.body.first
    refute Ryac::AstUtils.can_omit_parens?(call)
  end

  def test_can_omit_parens_false_when_first_arg_is_regex
    ast = Prism.parse("foo(/bar/)").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_when_kwarg_value_has_block
    ast = Prism.parse("foo(a: bar { })").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  def test_can_omit_parens_false_when_splat_arg_has_block
    ast = Prism.parse("foo(*bar { })").value.statements.body.first
    refute Ryac::AstUtils.can_omit_parens?(ast)
  end

  # unwrap_statements

  def test_unwrap_statements_nil
    assert_nil Ryac::AstUtils.unwrap_statements(nil)
  end

  def test_unwrap_statements_single
    ast = Prism.parse("1").value.statements
    result = Ryac::AstUtils.unwrap_statements(ast)
    assert_equal 1, result.value
  end

  def test_unwrap_statements_multiple
    ast = Prism.parse("1;2").value.statements
    result = Ryac::AstUtils.unwrap_statements(ast)
    assert_equal 2, result.body.size
  end

  def test_unwrap_statements_parens
    ast = Prism.parse("(1)").value.statements.body.first
    result = Ryac::AstUtils.unwrap_statements(ast)
    assert_equal 1, result.value
  end

  # simple_negatable?

  def test_simple_negatable_local_var
    ast = Prism.parse("x").value.statements.body.first
    assert Ryac::AstUtils.simple_negatable?(ast)
  end

  def test_simple_negatable_false_for_logical_op
    ast = Prism.parse("a || b").value.statements.body.first
    refute Ryac::AstUtils.simple_negatable?(ast)
  end

  def test_simple_negatable_false_for_middle_method
    ast = Prism.parse("a + b").value.statements.body.first
    refute Ryac::AstUtils.simple_negatable?(ast)
  end

  def test_simple_negatable_true_for_regular_call
    ast = Prism.parse("foo.bar").value.statements.body.first
    assert Ryac::AstUtils.simple_negatable?(ast)
  end

  # first_arg_is_regex?

  def test_first_arg_is_regex_true
    ast = Prism.parse("/foo/").value.statements.body.first
    assert Ryac::AstUtils.first_arg_is_regex?(ast)
  end

  def test_first_arg_is_regex_interpolated
    ast = Prism.parse('/foo#{1}/').value.statements.body.first
    assert Ryac::AstUtils.first_arg_is_regex?(ast)
  end

  def test_first_arg_is_regex_false
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.first_arg_is_regex?(ast)
  end

  # ends_with_name_char?

  def test_ends_with_name_char_string_false
    ast = Prism.parse('"hello"').value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_integer_false
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_local_var_true
    ast = Prism.parse("x = 1; x").value.statements.body[1]
    assert Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_bare_symbol_true
    ast = Prism.parse(":foo").value.statements.body.first
    assert Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_quoted_symbol_false
    ast = Prism.parse(':"foo"').value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_or_follows_right
    ast = Prism.parse("x = 1; x || 42").value.statements.body[1]
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_and_follows_right
    ast = Prism.parse("x = 1; x && 42").value.statements.body[1]
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_call_with_parens_false
    ast = Prism.parse("foo(1)").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_bare_method_true
    ast = Prism.parse("foo.bar").value.statements.body.first
    assert Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_bang_method_false
    ast = Prism.parse("foo.bar!").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_predicate_method_false
    ast = Prism.parse("foo.bar?").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_with_block_false
    ast = Prism.parse("foo {}").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_binary_op_right
    ast = Prism.parse("x = 1; x + 42").value.statements.body[1]
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_unary_not
    ast = Prism.parse("x = 1; !x").value.statements.body[1]
    assert Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_yield_no_args
    ast = Prism.parse("def foo;yield;end").value.statements.body.first.body.body.first
    assert Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_yield_with_args
    ast = Prism.parse("def foo;yield(1);end").value.statements.body.first.body.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_assignment
    ast = Prism.parse("x = 42").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_or_assign
    ast = Prism.parse("x = 1; x ||= 42").value.statements.body[1]
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_range_with_right
    ast = Prism.parse("1..42").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_range_without_right
    ast = Prism.parse("1..").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_ivar_false
    ast = Prism.parse("@x").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_array_false
    ast = Prism.parse("[1,2]").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_hash_false
    ast = Prism.parse("{a: 1}").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_rescue_modifier_false
    ast = Prism.parse("foo rescue nil").value.statements.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_super_no_args
    ast = Prism.parse("def foo;super;end").value.statements.body.first.body.body.first
    assert Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_super_with_args
    ast = Prism.parse("def foo;super(1);end").value.statements.body.first.body.body.first
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  def test_ends_with_name_char_index_assign
    ast = Prism.parse("x=[];x[0]=42").value.statements.body[1]
    refute Ryac::AstUtils.ends_with_name_char?(ast)
  end

  # ends_with_method_suffix?

  def test_ends_with_method_suffix_regular_method
    ast = Prism.parse("foo.bar").value.statements.body.first
    refute Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_bang_method
    ast = Prism.parse("foo.bar!").value.statements.body.first
    assert Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_predicate_method
    ast = Prism.parse("foo.bar?").value.statements.body.first
    assert Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_with_parens_false
    ast = Prism.parse("foo.bar!(1)").value.statements.body.first
    refute Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_integer_false
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_or_follows_right
    ast = Prism.parse("x = 1; x || foo.bar!").value.statements.body[1]
    assert Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_bare_symbol_with_suffix
    ast = Prism.parse(":foo?").value.statements.body.first
    assert Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_bare_symbol_without_suffix
    ast = Prism.parse(":foo").value.statements.body.first
    refute Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_quoted_symbol_false
    ast = Prism.parse(':"foo?"').value.statements.body.first
    refute Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_assignment
    ast = Prism.parse("x = foo.bar!").value.statements.body.first
    assert Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_binary_op
    ast = Prism.parse("x = 1; x + foo.bar!").value.statements.body[1]
    assert Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_with_block_false
    ast = Prism.parse("foo.bar! {}").value.statements.body.first
    refute Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_unary_not
    ast = Prism.parse("x = 1; !x").value.statements.body[1]
    refute Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  def test_ends_with_method_suffix_index_assign
    ast = Prism.parse("x=[];x[0]=foo.bar!").value.statements.body[1]
    assert Ryac::AstUtils.ends_with_method_suffix?(ast)
  end

  # needs_ternary_q_space?

  def test_needs_ternary_q_space_for_name_char
    ast = Prism.parse("foo.bar").value.statements.body.first
    assert Ryac::AstUtils.needs_ternary_q_space?(ast)
  end

  def test_needs_ternary_q_space_for_suffix
    ast = Prism.parse("foo.bar!").value.statements.body.first
    assert Ryac::AstUtils.needs_ternary_q_space?(ast)
  end

  def test_needs_ternary_q_space_false_for_integer
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.needs_ternary_q_space?(ast)
  end

  # ternary_needs_parens? — additional cases

  def test_ternary_needs_parens_after_paren_false
    source = "(z ?1:2)"
    inner = Prism.parse(source).value.statements.body.first
    ternary = inner.body.body.first
    refute Ryac::AstUtils.ternary_needs_parens?(ternary, source)
  end

  def test_ternary_needs_parens_after_bracket_false
    source = "[z ?1:2]"
    arr = Prism.parse(source).value.statements.body.first
    ternary = arr.elements.first
    refute Ryac::AstUtils.ternary_needs_parens?(ternary, source)
  end

  def test_ternary_needs_parens_after_newline_false
    source = "a=1\nz ?1:2"
    ast = Prism.parse(source).value.statements.body[1]
    refute Ryac::AstUtils.ternary_needs_parens?(ast, source)
  end

  def test_ternary_needs_parens_after_equal_sign_false
    source = "z=1;a=z ?1:2"
    assign = Prism.parse(source).value.statements.body[1]
    ternary = assign.value
    refute Ryac::AstUtils.ternary_needs_parens?(ternary, source)
  end

  def test_ternary_needs_parens_default_true
    # ternary after a comma: foo(z ?1:2) — the z ternary starts after comma
    source = "foo(1,z ?1:2)"
    call = Prism.parse(source).value.statements.body.first
    ternary = call.arguments.arguments[1]
    assert Ryac::AstUtils.ternary_needs_parens?(ternary, source)
  end

  # location_key

  def test_location_key_with_prism_node
    ast = Prism.parse("foo").value.statements.body.first
    assert_equal [0, 3], Ryac::AstUtils.location_key(ast)
  end

  def test_location_key_with_fake_node
    fake = FakeNodeSupport::FakeNode.new(5)
    assert_equal [5, 5], Ryac::AstUtils.location_key(fake)
  end

  # TypeProf nodes carry no location of their own — the key comes from the
  # Prism node behind them.
  def test_location_key_reads_through_to_the_prism_node
    prism_node = Prism.parse("bar").value.statements.body.first
    wrapper = Object.new
    wrapper.instance_variable_set(:@raw_node, prism_node)
    assert_equal [0, 3], Ryac::AstUtils.location_key(wrapper)
  end

  # A node nothing can point back at cannot be renamed, so this refuses rather
  # than inventing a key that would silently never match a patch site.
  def test_location_key_rejects_a_node_with_no_source_location
    assert_raises(ArgumentError) { Ryac::AstUtils.location_key(Object.new) }
  end

  # has_block?

  def test_has_block_true
    ast = Prism.parse("foo {}").value.statements.body.first
    assert Ryac::AstUtils.has_block?(ast)
  end

  def test_has_block_false
    ast = Prism.parse("foo(1)").value.statements.body.first
    refute Ryac::AstUtils.has_block?(ast)
  end

  # modifier_conditional? / modifier_loop? direct tests

  def test_modifier_conditional_false_for_block_unless
    ast = Prism.parse("unless y;x;end").value.statements.body.first
    refute Ryac::AstUtils.modifier_conditional?(ast)
  end

  def test_modifier_loop_false_for_block_while
    ast = Prism.parse("while y;x;end").value.statements.body.first
    refute Ryac::AstUtils.modifier_loop?(ast)
  end

  def test_modifier_loop_false_for_block_until
    ast = Prism.parse("until y;x;end").value.statements.body.first
    refute Ryac::AstUtils.modifier_loop?(ast)
  end

  def test_modifier_loop_false_for_other_node
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.modifier_loop?(ast)
  end

  def test_modifier_conditional_false_for_other_node
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.modifier_conditional?(ast)
  end

  # single_statement_body? with non-StatementsNode

  def test_single_statement_body_non_statements_node
    ast = Prism.parse("42").value.statements.body.first
    assert Ryac::AstUtils.single_statement_body?(ast)
  end

  # first_arg_starts_with_brace? — recursive call chain

  def test_first_arg_starts_with_brace_hash
    ast = Prism.parse("{a: 1}").value.statements.body.first
    assert Ryac::AstUtils.first_arg_starts_with_brace?(ast)
  end

  def test_first_arg_starts_with_brace_non_hash
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.first_arg_starts_with_brace?(ast)
  end

  # contains_bare_block? edge cases

  def test_contains_bare_block_lambda_false
    ast = Prism.parse("->{ 1 }").value.statements.body.first
    refute Ryac::AstUtils.contains_bare_block?(ast)
  end

  def test_contains_bare_block_array_false
    ast = Prism.parse("[1, 2]").value.statements.body.first
    refute Ryac::AstUtils.contains_bare_block?(ast)
  end

  def test_contains_bare_block_integer_false
    ast = Prism.parse("42").value.statements.body.first
    refute Ryac::AstUtils.contains_bare_block?(ast)
  end
end
