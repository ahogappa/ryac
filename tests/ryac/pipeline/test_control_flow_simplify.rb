# frozen_string_literal: true

require_relative '../../test_helper'

class TestControlFlowSimplify < Minitest::Test
  # --- tail return: the value of a def is its last expression ---

  def test_tail_return_removed
    assert_equal 'def f(x);y=x+1;y*2;end', @stage.call('def f(x);y=x+1;return y*2;end')
  end

  def test_tail_return_removed_in_endless_def
    assert_equal 'def f = 1', @stage.call('def f = return 1')
  end

  # `return a, b` is the array [a, b] spelled longer; `return *a` splats
  # into a value the bare expression would not, so the splat keeps its
  # return.
  def test_multi_value_return_becomes_array
    assert_equal 'def f(x);[x,1];end', @stage.call('def f(x);return x,1;end')
    assert_equal 'def f(a);return *a;end', @stage.call('def f(a);return *a;end')
  end

  def test_bare_tail_return_kept
    assert_equal 'def f(x);x.go;return;end', @stage.call('def f(x);x.go;return;end')
  end

  def test_mid_body_return_kept
    assert_equal 'def f(x);return 0 if x.nil?;x*2;end',
                 @stage.call('def f(x);return 0 if x.nil?;x*2;end')
  end

  # Tail position extends through every construct whose value the def
  # passes along; dropping the return composes with the modifier and
  # ternary rewrites inside the same fixpoint.
  def test_tail_returns_in_both_arms_removed
    assert_equal 'def f(x);x>0?1:2;end',
                 @stage.call('def f(x);if x>0;return 1;else;return 2;end;end')
  end

  def test_tail_returns_in_elsif_chain_removed
    assert_equal 'def f(x);x>0?:pos : x<0?:neg : :zero;end',
                 @stage.call('def f(x);if x>0;return :pos;elsif x<0;return :neg;else;return :zero;end;end')
  end

  def test_tail_guard_if_composes_to_modifier
    assert_equal 'def f(x);1 if x>0;end',
                 @stage.call('def f(x);if x>0;return 1;end;end')
  end

  def test_tail_return_in_modifier_if_removed
    assert_equal 'def f(x);:neg if x<0;end',
                 @stage.call('def f(x);return :neg if x<0;end')
  end

  def test_tail_returns_in_case_removed
    assert_equal 'def f(x);case x;when 1;:a;when 2;:b;else;:c;end;end',
                 @stage.call('def f(x);case x;when 1;return :a;when 2;return :b;else;return :c;end;end')
  end

  def test_tail_returns_in_case_match_removed
    assert_equal 'def f(x);case x;in Integer;:int;in String;:str;end;end',
                 @stage.call('def f(x);case x;in Integer;return :int;in String;return :str;end;end')
  end

  def test_tail_returns_in_def_rescue_removed
    assert_equal 'def f;go;rescue;:err;end',
                 @stage.call('def f;return go;rescue;return :err;end')
  end

  def test_tail_return_with_ensure_removed
    assert_equal 'def f(log);:val;ensure;log.push(1);end',
                 @stage.call('def f(log);return :val;ensure;log.push(1);end')
  end

  # Loops and blocks are opaque: a return there escapes the method for
  # real. The loop still converts to modifier form around it.
  def test_return_inside_loop_kept
    assert_equal 'def f(x);return 1 while x;end',
                 @stage.call('def f(x);while x;return 1;end;end')
  end

  def test_return_inside_block_kept
    assert_equal 'def f(a);a.map{return 1};end',
                 @stage.call('def f(a);a.map{return 1};end')
  end
  def setup
    @stage = Ryac::Pipeline::ControlFlowSimplify.new
  end

  def test_if_to_modifier
    assert_equal "bar if foo", @stage.call("if foo;bar;end")
  end

  def test_unless_to_negated_if
    assert_equal "bar if !foo", @stage.call("unless foo;bar;end")
  end

  def test_if_else_to_ternary
    result = @stage.call("if foo;bar;else;baz;end")
    assert_equal "foo ? bar : baz", result
  end

  def test_while_to_modifier
    assert_equal "bar while foo", @stage.call("while foo;bar;end")
  end

  def test_until_to_modifier
    assert_equal "bar until foo", @stage.call("until foo;bar;end")
  end

  def test_multi_statement_if_not_simplified
    assert_equal "if foo;bar;baz;end", @stage.call("if foo;bar;baz;end")
  end

  def test_multi_statement_while_not_simplified
    assert_equal "while foo;bar;baz;end", @stage.call("while foo;bar;baz;end")
  end

  def test_unless_complex_condition_stays_unless
    # Complex condition (binary op) → can't negate simply, stays as unless
    assert_equal "bar unless a+b", @stage.call("unless a+b;bar;end")
  end

  def test_elsif_to_nested_ternary
    result = @stage.call("if a;b;elsif c;d;else;e;end")
    assert_equal "a ? b : c ? d : e", result
  end

  def test_return_in_then_prevents_ternary
    assert_equal "if foo;return 1;else;2;end", @stage.call("if foo;return 1;else;2;end")
  end

  def test_break_in_then_prevents_ternary
    assert_equal "if foo;break 1;else;2;end", @stage.call("if foo;break 1;else;2;end")
  end

  def test_next_in_then_prevents_ternary
    assert_equal "if foo;next 1;else;2;end", @stage.call("if foo;next 1;else;2;end")
  end

  def test_yield_in_then_prevents_ternary
    assert_equal "if foo;yield 1;else;2;end", @stage.call("if foo;yield 1;else;2;end")
  end

  def test_semicolon_in_then_prevents_ternary
    assert_equal "if foo;a;b;else;c;end", @stage.call("if foo;a;b;else;c;end")
  end

  def test_return_in_else_prevents_ternary
    assert_equal "if foo;1;else;return 2;end", @stage.call("if foo;1;else;return 2;end")
  end

  def test_semicolon_in_else_prevents_ternary
    assert_equal "if foo;1;else;a;b;end", @stage.call("if foo;1;else;a;b;end")
  end

  def test_modifier_if_in_then_wraps_parens
    assert_equal "a ? (b if c):d", @stage.call("if a;b if c;else;d;end")
  end

  def test_ternary_no_space_when_cond_ends_with_paren
    # Condition ending with ) → no space needed before ?
    result = @stage.call("if foo();1;else;2;end")
    assert_equal "foo()?1:2", result
  end

  def test_ternary_space_when_cond_ends_with_name
    result = @stage.call("if foo;1;else;2;end")
    assert_equal "foo ? 1:2", result
  end

  def test_ternary_colon_space_when_then_ends_with_bang_method
    # stop!:foo would be parsed as stop! with keyword arg :foo
    result = @stage.call("if x;stop!;else;go;end")
    assert_equal "x ? stop! : go", result
  end

  def test_ternary_colon_space_when_then_ends_with_predicate_method
    result = @stage.call("if x;valid?;else;go;end")
    assert_equal "x ? valid? : go", result
  end

  def test_ternary_no_extra_space_for_unary_bang
    # !!1 ends with unary !, not a method suffix — no space needed before :
    result = @stage.call("if x;!!1;else;!1;end")
    assert_equal "x ? !!1:!1", result
  end

  def test_ternary_colon_space_when_else_starts_with_symbol
    result = @stage.call("if foo();1;else;:foo;end")
    assert_equal "foo()?1: :foo", result
  end

  def test_unless_multi_statement_to_block_if
    result = @stage.call("unless foo;a;b;end")
    assert_equal "if !foo;a;b;end", result
  end

  def test_modifier_if_already_not_touched
    assert_equal "bar if foo", @stage.call("bar if foo")
  end

  def test_modifier_while_already_not_touched
    assert_equal "bar while foo", @stage.call("bar while foo")
  end

  def test_iterative_simplification
    # Nested if → one pass folds the conditions, the next takes modifier form
    result = @stage.call("if a;if b;c;end;end")
    assert_equal "c if a&&b", result
  end

  def test_and_condition_wrapped_in_ternary
    # and has lower precedence than ?:, so must be wrapped in parens
    result = @stage.call("if a and b;c;else;d;end")
    assert_equal "(a and b)?c : d", result
  end

  def test_or_condition_wrapped_in_ternary
    result = @stage.call("if a or b;c;else;d;end")
    assert_equal "(a or b)?c : d", result
  end

  def test_and_or_in_elsif_chain
    result = @stage.call("if a and b;c;elsif d or e;f;else;g;end")
    assert_equal "(a and b)?c : (d or e)?f : g", result
  end

  def test_ternary_space_when_cond_ends_with_symbol
    # :raise? would be parsed as a symbol if no space before ?
    result = @stage.call("if x==:raise;:fail;else;x;end")
    assert_equal "x==:raise ? :fail : x", result
  end

  def test_no_modifier_when_body_uses_var_assigned_in_condition
    # `return res if (res = foo())` is invalid — `res` is not defined
    # when the left side of modifier-if is parsed. Must keep block form.
    assert_equal "if (res=foo());return res;end", @stage.call("if (res=foo());return res;end")
  end

  def test_no_modifier_when_body_reads_var_from_condition_assignment
    assert_equal "if (x=bar());puts(x);end", @stage.call("if (x=bar());puts(x);end")
  end

  def test_modifier_ok_when_body_does_not_use_condition_var
    # Body doesn't reference the variable assigned in condition — modifier is safe
    assert_equal "puts(1) if (x=bar())", @stage.call("if (x=bar());puts(1);end")
  end

  def test_ternary_space_when_negated_variable_condition
    # !align_to?0 would be parsed as calling align_to? method
    result = @stage.call("if !align_to;0;else;align_to.column;end")
    assert_equal "!align_to ? 0:align_to.column", result
  end

  def test_paren_modifier_if_inside_array_literal
    # [a, b if c] is invalid Ruby — in value position the modifier needs parens
    assert_equal "[a,(b if x)]", @stage.call("[a,if x;b;end]")
  end

  def test_paren_modifier_if_after_open_bracket
    assert_equal "[(b if x)]", @stage.call("[if x;b;end]")
  end

  # `x = if c; b; end` assigns nil when c is false; a bare `x=b if c` would
  # skip the assignment entirely and keep x's previous value. The self-hosted
  # minifier looped forever on exactly this: a chain-walking loop whose
  # `current = ... ? ... : nil` step silently stopped clearing current.
  def test_assignment_value_if_keeps_assignment
    assert_equal "x=(b if c)", @stage.call("x=if c;b;end")
  end

  def test_assignment_value_while_not_simplified
    assert_equal "x=while c;b;end", @stage.call("x=while c;b;end")
  end

  # In the modifier form the body parses before the condition binds its
  # local, so `puts x while x = gets` raises NameError — every rewrite path
  # must refuse when the condition binds a local the body reads.
  def test_while_condition_binding_local_used_in_body_not_rewritten
    input = "while x = gets;puts x;end"
    assert_equal input, @stage.call(input)
  end

  def test_until_condition_binding_local_used_in_body_not_rewritten
    input = "until (x = step).nil?;puts x;end"
    assert_equal input, @stage.call(input)
  end

  def test_while_condition_binding_unused_local_still_rewritten
    assert_equal "puts y while x = gets", @stage.call("while x = gets;puts y;end")
  end

  def test_if_condition_compound_write_used_in_body_not_rewritten
    input = "if (x ||= foo);x.bar;end"
    assert_equal input, @stage.call(input)
  end

  # Block form stays safe (condition runs before the body parses its
  # locals at runtime); only the modifier form must be refused.
  def test_unless_condition_compound_write_keeps_block_form
    assert_equal "if !(x &&= foo);x.bar;end", @stage.call("unless (x &&= foo);x.bar;end")
  end

  def test_if_condition_operator_write_used_in_body_not_rewritten
    input = "if (x += 1) > 3;puts x;end"
    assert_equal input, @stage.call(input)
  end

  def test_no_ternary_with_multi_assignment_body
    # variable,default=expr inside ternary is invalid (comma conflicts)
    input = "if foo;a,b=bar;else;a,b=baz;end"
    assert_equal input, @stage.call(input)
  end

  def test_ternary_wraps_parens_when_followed_by_operator
    # `off=if cond;-1;else;1;end*(expr)` — the if...end result is multiplied.
    # Ternary must be parenthesized: `off=(cond ?-1:1)*(expr)`
    input = 'off=if $1=="-";-1;else;1;end*((x+y)*60)'
    result = @stage.call(input)
    assert_equal 'off=($1=="-"?-1:1)*((x+y)*60)', result
  end

  def test_multi_statement_until_not_simplified
    assert_equal "until foo;bar;baz;end", @stage.call("until foo;bar;baz;end")
  end

  def test_unless_complex_condition_multi_statement_stays
    assert_equal "unless a+b;c;d;end", @stage.call("unless a+b;c;d;end")
  end

  def test_unless_negatable_with_var_assignment_uses_block_form
    assert_equal "if !(x=foo());puts(x);end", @stage.call("unless (x=foo());puts(x);end")
  end

  def test_paren_modifier_if_inside_argument_context
    assert_equal "foo((b if x))", @stage.call("foo(if x;b;end)")
  end

  def test_no_modifier_while_inside_array
    assert_equal "[while x;b;end]", @stage.call("[while x;b;end]")
  end

  def test_no_modifier_until_inside_array
    assert_equal "[until x;b;end]", @stage.call("[until x;b;end]")
  end

  def test_modifier_control_flow_in_else_wraps_parens
    assert_equal "a ? b : (c if d)", @stage.call("if a;b;else;c if d;end")
  end

  def test_unless_in_collection_context_uses_block_form
    assert_equal "[(b if !x)]", @stage.call("[unless x;b;end]")
  end

  # --- sole nested conditional: an if wrapping only an if folds to && ---

  def test_sole_nested_if_folds_and_takes_modifier_form
    assert_equal 'puts 1 if a&&b', @stage.call('if a;if b;puts 1;end;end')
  end

  def test_sole_nested_if_with_multi_statement_body
    assert_equal 'if a&&b;x;y;end', @stage.call('if a;if b;x;y;end;end')
  end

  def test_sole_nested_if_parenthesizes_loose_conditions
    assert_equal 'if (a||c)&&b;x;y;end', @stage.call('if a||c;if b;x;y;end;end')
  end

  def test_sole_nested_fold_composes_through_the_fixpoint
    assert_equal 'if a&&!b;x;y;end', @stage.call('if a;unless b;x;y;end;end')
    assert_equal 'if a&&b&&c;x;y;end', @stage.call('if a;if b;if c;x;y;end;end;end')
  end

  def test_inner_if_with_else_does_not_fold
    assert_equal 'b ? x : y if a', @stage.call('if a;if b;x;else;y;end;end')
  end

  def test_inner_elsif_does_not_fold
    assert_equal 'b ? x : c ? y : () if a', @stage.call('if a;if b;x;elsif c;y;end;end')
  end

  # An elsif chain with no else has nil for its untaken case; `()` spells
  # that in ternary position, in statement and value position alike.
  def test_elsif_without_else_to_ternary
    assert_equal 'a ? b : c ? d : ()', @stage.call('if a;b;elsif c;d;end')
    assert_equal 'x = (a ? b : c ? d : ())', @stage.call('x = if a;b;elsif c;d;end')
  end

  # A multiple assignment's comma cannot live inside a ternary branch —
  # json's IO/limit swap sits in exactly this elsif shape.
  def test_multi_write_in_elsif_prevents_ternary
    assert_equal 'if a;b;elsif c;x,y=1,2;end',
                 @stage.call('if a;b;elsif c;x,y=1,2;end')
  end
end
