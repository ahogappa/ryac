# frozen_string_literal: true

require_relative '../../test_helper'

class TestCompactor < Minitest::Test
  def setup
    @stage = Ryac::Pipeline::Compactor.new
  end

  def test_index_or_write_preserves_parens
    # (@routes[verb] ||= []) << sig  must keep parens — without them,
    # @routes[verb]||=[]<<sig  parses as  @routes[verb] ||= ([] << sig)
    # which creates a fresh single-element array each time instead of accumulating.
    assert_equal '(@routes[verb]||=[])<<sig', @stage.call('(@routes[verb] ||= []) << sig')
  end

  def test_index_and_write_preserves_parens
    assert_equal '(@cache[k]&&=v).frozen?', @stage.call('(@cache[k] &&= v).frozen?')
  end

  def test_index_operator_write_preserves_parens
    assert_equal '(@counts[k]+=1)==10', @stage.call('(@counts[k] += 1) == 10')
  end

  def test_call_or_write_preserves_parens
    assert_equal '(obj.val||=0)+1', @stage.call('(obj.val ||= 0) + 1')
  end

  def test_call_and_write_preserves_parens
    assert_equal '(obj.val&&=x).to_s', @stage.call('(obj.val &&= x).to_s')
  end

  def test_call_operator_write_preserves_parens
    assert_equal '(obj.count+=1)==5', @stage.call('(obj.count += 1) == 5')
  end

  def test_same_precedence_comparison_preserves_parens
    # =~ and == have same precedence; parens are required
    assert_equal '(line=~/\s*\z/)==range.last_column', @stage.call('(line =~ /\s*\z/) == range.last_column')
  end

  def test_raise_not_converted_by_compactor
    # raise→fail is now handled by METHOD_ALIASES at L5, not compactor
    assert_equal 'raise("error")', @stage.call('raise "error"')
    assert_equal 'raise(ArgumentError,"bad")', @stage.call('raise ArgumentError, "bad"')
  end

  def test_first_not_converted_by_compactor
    # .first→[0] is now handled by method transforms at L5, not compactor
    assert_equal 'arr.first', @stage.call('arr.first')
    assert_equal 'arr.first(3)', @stage.call('arr.first(3)')
    assert_equal 'arr.first{it>0}', @stage.call('arr.first { it > 0 }')
    assert_equal 'first', @stage.call('first')
    assert_equal 'arr&.first', @stage.call('arr&.first')
  end

  def test_global_var_symbol_with_quote
    # :$" is a valid symbol for the $" global variable
    assert_equal ':$"', @stage.call(':$"')
    code = '{:$" =>[:$LOADED_FEATURES]}'
    result = @stage.call(code)
    pr = Prism.parse(result)
    assert_empty pr.errors, "Compacted code has syntax errors: #{result}"
  end

  # --- Basic compaction ---

  def test_removes_comments_and_joins_with_semicolons
    assert_equal 'x=1;y=2', @stage.call("x = 1 # comment\ny = 2")
  end

  def test_multiple_statements
    assert_equal 'a=1;b=2;c=3', @stage.call("a = 1\nb = 2\nc = 3")
  end

  # --- Literals ---

  def test_string_double_quoted
    assert_equal '"hello"', @stage.call('"hello"')
  end

  def test_string_single_quoted
    assert_equal '"hello"', @stage.call("'hello'")
  end

  def test_integer_and_float
    assert_equal '42', @stage.call('42')
    assert_equal '3.14', @stage.call('3.14')
  end

  def test_rational_and_imaginary
    assert_equal '1r', @stage.call('1r')
    assert_equal '1i', @stage.call('1i')
  end

  def test_symbol_simple
    assert_equal ':foo', @stage.call(':foo')
  end

  def test_symbol_with_special_chars
    assert_equal ':"foo bar"', @stage.call(':"foo bar"')
  end

  def test_array_literal
    assert_equal '[1,2,3]', @stage.call('[1, 2, 3]')
  end

  def test_array_percent_w
    assert_equal '%w[foo bar]', @stage.call('%w[foo bar]')
  end

  def test_array_percent_i
    assert_equal '%i[foo bar]', @stage.call('%i[foo bar]')
  end

  def test_range_inclusive
    assert_equal '(1..10)', @stage.call('1..10')
  end

  def test_range_exclusive
    assert_equal '(1...10)', @stage.call('1...10')
  end

  def test_hash_symbol_keys
    assert_equal '{a:1,b:2}', @stage.call('{a: 1, b: 2}')
  end

  def test_hash_string_keys
    assert_equal '{"x"=>1}', @stage.call('{"x" => 1}')
  end

  def test_hash_shorthand
    assert_equal '{x:}', @stage.call('{x:}')
  end

  def test_regexp
    assert_equal '/foo/i', @stage.call('/foo/i')
  end

  def test_interpolated_string
    assert_equal '"hello #{name}"', @stage.call('"hello #{name}"')
  end

  def test_interpolated_symbol
    assert_equal ':"hello_#{x}"', @stage.call(':"hello_#{x}"')
  end

  def test_interpolated_regexp
    assert_equal '/foo#{bar}/i', @stage.call('/foo#{bar}/i')
  end

  # --- Variable writes ---

  def test_local_variable_write
    assert_equal 'x=1', @stage.call('x = 1')
  end

  def test_instance_variable_write
    assert_equal '@x=1', @stage.call('@x = 1')
  end

  def test_class_variable_write
    assert_equal '@@x=1', @stage.call('@@x = 1')
  end

  def test_global_variable_write
    assert_equal '$x=1', @stage.call('$x = 1')
  end

  def test_constant_write
    assert_equal 'X=1', @stage.call('X = 1')
  end

  def test_constant_path_write
    assert_equal 'Foo::BAR=1', @stage.call('Foo::BAR = 1')
  end

  # --- Compound writes ---

  def test_instance_var_operator_write
    assert_equal '@x+=1', @stage.call('@x += 1')
  end

  def test_class_var_or_write
    assert_equal '@@x||=1', @stage.call('@@x ||= 1')
  end

  def test_global_var_and_write
    assert_equal '$x&&=1', @stage.call('$x &&= 1')
  end

  def test_constant_or_write
    assert_equal 'X||=1', @stage.call('X ||= 1')
  end

  def test_constant_path_or_write
    assert_equal 'Foo::X||=1', @stage.call('Foo::X ||= 1')
  end

  # --- Method definitions ---

  def test_method_def_with_all_param_types
    assert_equal 'def f(a,b=1,*c,d:,e:2,**f,&g);end',
      @stage.call('def f(a, b=1, *c, d:, e: 2, **f, &g); end')
  end

  def test_method_def_with_body
    assert_equal 'def f;return 1;end', @stage.call('def f; return 1; end')
  end

  # --- Method calls ---

  def test_setter_call
    assert_equal 'obj.name=val', @stage.call('obj.name = val')
  end

  def test_safe_navigation
    assert_equal 'obj&.foo', @stage.call('obj&.foo')
  end

  def test_block_call
    assert_equal '[1,2].map{|x|x+1}', @stage.call('[1,2].map { |x| x + 1 }')
  end

  def test_block_pass
    assert_equal 'foo(&block)', @stage.call('foo(&block)')
  end

  def test_index_access
    assert_equal 'arr[0]', @stage.call('arr[0]')
  end

  def test_index_assign
    assert_equal 'arr[0]=1', @stage.call('arr[0] = 1')
  end

  def test_safe_nav_index
    assert_equal 'arr&.[](0)', @stage.call('arr&.[](0)')
  end

  def test_splat_argument
    assert_equal 'foo(*args)', @stage.call('foo(*args)')
  end

  # --- Unary operators ---

  def test_unary_not
    assert_equal '!x', @stage.call('!x')
  end

  def test_unary_not_complex
    assert_equal '!(x&&y)', @stage.call('!(x && y)')
  end

  def test_unary_minus
    assert_equal '-x', @stage.call('-x')
  end

  def test_unary_plus
    assert_equal '+x', @stage.call('+x')
  end

  # --- Binary operator precedence ---

  def test_higher_precedence_preserved
    assert_equal 'a+b*c', @stage.call('a + b * c')
  end

  def test_lower_precedence_wrapped
    assert_equal '(a+b)*c', @stage.call('(a + b) * c')
  end

  # --- Control flow ---

  def test_if_elsif_else
    assert_equal 'if x;1;elsif y;2;else;3;end',
      @stage.call('if x; 1; elsif y; 2; else; 3; end')
  end

  def test_if_with_else_nil_omitted
    assert_equal 'if x;1;end', @stage.call('if x; 1; else; nil; end')
  end

  def test_unless
    assert_equal 'unless x;1;end', @stage.call('unless x; 1; end')
  end

  def test_while
    assert_equal 'while x;y;end', @stage.call('while x; y; end')
  end

  def test_until
    assert_equal 'until x;y;end', @stage.call('until x; y; end')
  end

  def test_do_while
    assert_equal 'begin;x;end while cond', @stage.call("begin; x; end while cond")
  end

  def test_do_until
    assert_equal 'begin;x;end until cond', @stage.call("begin; x; end until cond")
  end

  def test_case_when
    assert_equal 'case x;when 1;:a;when 2;:b;else;:c;end',
      @stage.call('case x; when 1; :a; when 2; :b; else; :c; end')
  end

  def test_for
    assert_equal 'for i in arr;puts(i);end', @stage.call('for i in arr; puts i; end')
  end

  # --- Logic ---

  def test_and_operator
    assert_equal 'x&&y', @stage.call('x && y')
  end

  def test_or_operator
    assert_equal 'x||y', @stage.call('x || y')
  end

  def test_and_keyword_becomes_operator
    assert_equal 'x&&y', @stage.call('x and y')
  end

  def test_or_keyword_becomes_operator
    assert_equal 'x||y', @stage.call('x or y')
  end

  def test_and_wraps_or_operand
    assert_equal 'x&&(y||z)', @stage.call('x && (y || z)')
    assert_equal 'x&&(y||z)', @stage.call('x and (y or z)')
  end

  def test_or_drops_parens_around_tighter_and
    assert_equal 'x||y&&z', @stage.call('x or (y and z)')
  end

  # --- Return / Break / Next ---

  def test_return_with_value
    assert_equal 'def f;return 1;end', @stage.call('def f; return 1; end')
  end

  def test_return_without_value
    assert_equal 'def f;return;end', @stage.call('def f; return; end')
  end

  def test_break_with_value
    assert_equal 'break 1', @stage.call('break 1')
  end

  def test_next_with_value
    assert_equal 'next 1', @stage.call('next 1')
  end

  # --- Yield / Super ---

  def test_yield_no_args
    assert_equal 'def f;yield;end', @stage.call('def f; yield; end')
  end

  def test_yield_with_args
    assert_equal 'def f;yield(1,2);end', @stage.call('def f; yield(1, 2); end')
  end

  def test_super_no_args
    assert_equal 'def f;super();end', @stage.call('def f; super(); end')
  end

  def test_super_with_args
    assert_equal 'def f;super(1);end', @stage.call('def f; super(1); end')
  end

  def test_forwarding_super
    assert_equal 'def f;super;end', @stage.call('def f; super; end')
  end

  # --- Begin / Rescue / Ensure ---

  def test_begin_rescue_ensure
    assert_equal 'begin;x;rescue=>e;e;ensure;z;end',
      @stage.call('begin; x; rescue => e; e; ensure; z; end')
  end

  def test_rescue_modifier
    assert_equal '(x rescue ())', @stage.call('x rescue nil')
  end

  # --- Lambda ---

  def test_lambda
    assert_equal '->(x){x+1}', @stage.call('->(x) { x + 1 }')
  end

  # --- Multi-write ---

  def test_multi_write
    assert_equal 'a,b=1,2', @stage.call('a, b = 1, 2')
  end

  # --- Class / Module ---

  def test_class_with_superclass
    assert_equal 'class Foo<Bar;end', @stage.call('class Foo < Bar; end')
  end

  def test_module
    assert_equal 'module Foo;end', @stage.call('module Foo; end')
  end

  def test_singleton_class
    assert_equal 'class<<self;end', @stage.call('class << self; end')
  end

  def test_singleton_class_consolidation
    code = 'class Foo; def self.a; 1; end; def self.b; 2; end; def self.c; 3; end; def self.d; 4; end; end'
    assert_equal 'class Foo;class<<self;def a;1;end;def b;2;end;def c;3;end;def d;4;end;end;end',
      @stage.call(code)
  end

  # Grouping must not move statements across the run: an interleaved
  # statement breaks the run, and a run under the threshold stays plain.
  def test_singleton_consolidation_preserves_statement_order
    code = 'class Foo; def self.a; 1; end; X = 1; def self.b; 2; end; def self.c; 3; end; def self.d; 4; end; def self.e; 5; end; end'
    assert_equal 'class Foo;def self.a;1;end;X=1;class<<self;def b;2;end;def c;3;end;def d;4;end;def e;5;end;end;end',
      @stage.call(code)
  end

  # A `def self.x` nested in a grouped member's body defines a singleton
  # method at runtime either way — it must keep its `self.` inside the
  # class<<self block (dropping it would target the singleton's singleton).
  def test_singleton_consolidation_keeps_nested_self_defs
    code = 'module M; def self.a; def self.inner; 9; end; end; def self.b; 2; end; def self.c; 3; end; def self.d; 4; end; end'
    out = @stage.call(code)
    assert_equal 'module M;class<<self;def a;def self.inner;9;end;end;def b;2;end;def c;3;end;def d;4;end;end;end', out
    Module.new.module_eval(out.sub('module M', 'module MEvalCheck'))
  end

  def test_top_level_singleton_defs_group_like_class_bodies
    code = 'def self.a; 1; end; def self.b; 2; end; def self.c; 3; end; def self.d; 4; end'
    assert_equal 'class<<self;def a;1;end;def b;2;end;def c;3;end;def d;4;end;end', @stage.call(code)
  end

  # --- Alias / Undef ---

  def test_alias
    assert_equal 'alias foo bar', @stage.call('alias foo bar')
  end

  def test_undef
    assert_equal 'undef foo', @stage.call('undef foo')
  end

  # Interpolated symbols cannot drop their colon-quote syntax; plain names
  # in the same statement still do.
  def test_alias_interpolated_symbol
    assert_equal 'alias :"a#{1}" object_id', @stage.call('alias :"a#{1}" :object_id')
  end

  def test_undef_interpolated_symbol
    assert_equal 'undef :"m#{2}",to_s', @stage.call('undef :"m#{2}", :to_s')
  end

  # --- Defined / POST execution ---

  def test_defined
    assert_equal 'defined?(x)', @stage.call('defined?(x)')
  end

  def test_post_execution
    assert_equal 'END{cleanup}', @stage.call('END { cleanup }')
  end

  # --- Match / Pattern matching ---

  def test_match_write
    assert_equal '/(?<name>\w+)/=~str', @stage.call('/(?<name>\w+)/ =~ str')
  end

  def test_match_required
    assert_equal 'x=>Integer', @stage.call('x => Integer')
  end

  def test_match_predicate
    assert_equal 'x in Integer', @stage.call('x in Integer')
  end

  def test_case_in_pattern
    assert_equal 'case x;in [1,2];:yes;end',
      @stage.call('case x; in [1, 2]; :yes; end')
  end

  def test_hash_pattern
    assert_equal 'case x;in {a: Integer};:yes;end',
      @stage.call('case x; in {a: Integer}; :yes; end')
  end

  def test_find_pattern
    assert_equal 'case x;in [*,1,*];:yes;end',
      @stage.call('case x; in [*, 1, *]; :yes; end')
  end

  def test_alternation_pattern
    assert_equal 'case x;in 1 | 2;:yes;end',
      @stage.call('case x; in 1 | 2; :yes; end')
  end

  def test_capture_pattern
    assert_equal 'case x;in Integer=>n;n;end',
      @stage.call('case x; in Integer => n; n; end')
  end

  def test_nil_renders_as_empty_parens
    assert_equal 'a=();b=[(),()];c={x:()};d=foo(());e=(a=())',
      @stage.call("a = nil\nb = [nil, nil]\nc = { x: nil }\nd = foo(nil)\ne = (a = nil)")
  end

  def test_nil_in_parameter_defaults
    assert_equal 'def f(a=(),b:());[a,b,()];end',
      @stage.call('def f(a = nil, b: nil); [a, b, nil]; end')
  end

  def test_nil_in_jump_and_yield
    assert_equal 'def f;yield(());return ();end',
      @stage.call("def f\n  yield nil\n  return nil\nend")
  end

  # Pattern positions reject `()` — every pattern shape keeps the nil
  # spelling, while the case subject (an expression) converts.
  def test_nil_in_patterns_stays_nil
    assert_equal 'case ();in nil;1;in [nil,Integer];2;in nil | 1;3;in {a: nil};4;in (nil)=>n;n;end',
      @stage.call('case nil; in nil; 1; in [nil, Integer]; 2; in nil | 1; 3; in {a: nil}; 4; in (nil) => n; n; end')
  end

  def test_nil_in_rightward_patterns_stays_nil
    assert_equal 'v=();v=>nil;w=(v in nil)',
      @stage.call("v = nil\nv => nil\nw = (v in nil)")
  end

  # `()` in the input is the same nil literal this pass emits: it must
  # round-trip (doubled parens normalize to one pair), not collapse to
  # the empty string.
  def test_empty_parens_round_trip
    assert_equal 'x=();y=()',
      @stage.call("x = ()\ny = (())")
  end

  def test_pinned_variable
    assert_equal 'case x;in ^y;:yes;end',
      @stage.call('case x; in ^y; :yes; end')
  end

  # --- Constant path ---

  def test_constant_path_read
    assert_equal 'Foo::Bar', @stage.call('Foo::Bar')
  end

  def test_top_level_constant
    assert_equal '::Foo', @stage.call('::Foo')
  end

  # --- Dead code elimination ---

  def test_dead_code_after_return
    assert_equal 'return 1', @stage.call("return 1\nx = 2")
  end

  def test_dead_code_after_raise
    assert_equal 'raise', @stage.call("raise\nx = 1")
  end

  # --- Singleton class consolidation with mixed methods (lines 157-159) ---

  def test_singleton_consolidation_with_instance_methods
    code = 'class Foo; def self.a; 1; end; def self.b; 2; end; def self.c; 3; end; def self.d; 4; end; def bar; 5; end; end'
    assert_equal 'class Foo;class<<self;def a;1;end;def b;2;end;def c;3;end;def d;4;end;end;def bar;5;end;end',
      @stage.call(code)
  end

  # Flow only ends at the Kernel spellings; a receiver makes raise/fail an
  # ordinary method call and everything after it must survive.
  def test_receiver_raise_does_not_truncate
    assert_equal 'logger.raise(1);puts(2)', @stage.call("logger.raise(1)\nputs 2")
  end

  def test_receiverless_raise_still_truncates
    assert_equal 'raise("x")', @stage.call("raise \"x\"\nputs 2")
  end

  # --- PinnedExpressionNode (line 121) ---

  def test_pinned_expression
    assert_equal 'case x;in ^(1+2);:yes;end',
      @stage.call('case x; in ^(1+2); :yes; end')
  end

  # --- ShareableConstantNode (line 123) ---

  def test_shareable_constant
    assert_equal 'X=[1,2]',
      @stage.call("# shareable_constant_value: literal\nX = [1, 2]")
  end

  # --- CallTargetNode in multi-write (lines 124, 704) ---

  def test_multi_write_call_target
    assert_equal 'self.x,self.y=1,2', @stage.call('self.x, self.y = 1, 2')
  end

  # --- KeywordHashNode via yield (lines 125, 478, 479) ---

  def test_yield_keyword_hash
    assert_equal 'yield(a:1,b:2)', @stage.call('yield a: 1, b: 2')
  end

  # --- Safe navigation index assign (line 235) ---

  def test_safe_nav_index_assign
    assert_equal 'obj&.[]=(0,val)', @stage.call('obj&.[]=(0, val)')
  end

  # --- Def body single parens unwrap (line 266) ---

  def test_def_body_single_parens_unwrap
    assert_equal 'def f;x+1;end', @stage.call("def f\n(x + 1)\nend")
  end

  # --- Case match else (line 351) ---

  def test_case_match_else
    assert_equal 'case x;in 1;:a;else;:b;end',
      @stage.call('case x; in 1; :a; else; :b; end')
  end

  # --- Regexp with %r{} delimiter and slashes (lines 432-448) ---

  def test_regexp_percent_r_with_slashes
    assert_equal '/foo\/bar/', @stage.call('%r{foo/bar}')
  end

  def test_regexp_percent_r_with_backslash_and_slash
    assert_equal '/foo\\\\\/bar/', @stage.call('%r{foo\\\\/bar}')
  end

  # --- Interpolated regexp with non-/ opening (line 528) ---

  def test_interp_regexp_percent_r
    assert_equal '/foo\/#{x}\/bar/', @stage.call('%r{foo/#{x}/bar}')
  end

  # --- EmbeddedVariableNode (line 545) ---

  def test_embedded_variable_ivar
    assert_equal '"hello #{@x}"', @stage.call('"hello #@x"')
  end

  # --- escape_for_dquote (lines 556-566) ---

  def test_escape_for_dquote_newline
    assert_equal '"line1\nline2#{x}"', @stage.call('%Q{line1\nline2#{x}}')
  end

  def test_escape_for_dquote_tab
    assert_equal '"col1\tcol2#{x}"', @stage.call('%Q{col1\tcol2#{x}}')
  end

  def test_escape_for_dquote_cr
    assert_equal '"a\rb#{x}"', @stage.call('%Q{a\rb#{x}}')
  end

  def test_escape_for_dquote_null
    assert_equal '"a\0b#{x}"', @stage.call('%Q{a\0b#{x}}')
  end

  def test_escape_for_dquote_backslash
    assert_equal '"a\\\\b#{x}"', @stage.call('%Q{a\\\\b#{x}}')
  end

  def test_escape_for_dquote_double_quote
    assert_equal '"a\\"b#{x}"', @stage.call('%Q{a\\"b#{x}}')
  end

  def test_escape_for_dquote_hash_at
    assert_equal '"a\#@x b#{y}"', @stage.call(%q|%Q{a\#@x b#{y}}|)
  end

  def test_escape_for_dquote_hash_normal
    assert_equal '"a#b#{x}"', @stage.call('%Q{a#b#{x}}')
  end

  # --- ImplicitRestNode in multi-write (line 663) ---

  def test_multi_write_implicit_rest
    assert_equal 'a,* =1,2', @stage.call('a, = [1, 2]')
  end

  # --- Multi-write single value (line 673) ---

  def test_multi_write_single_value
    assert_equal 'a,b=x', @stage.call('a, b = x')
  end

  # --- ConstantTargetNode (line 683) ---

  def test_multi_write_constant_targets
    assert_equal 'A,B=1,2', @stage.call('A, B = 1, 2')
  end

  # --- ConstantPathTargetNode (line 685) ---

  def test_multi_write_constant_path_targets
    assert_equal 'Foo::A,Foo::B=1,2', @stage.call('Foo::A, Foo::B = 1, 2')
  end

  # --- Nested MultiTargetNode (lines 687-696) ---

  def test_multi_write_nested
    assert_equal 'a,b,c=[1,2],3', @stage.call('(a, b), c = [1, 2], 3')
  end

  def test_multi_write_nested_with_splat
    assert_equal 'a,*b,c=[1,2,3],4', @stage.call('(a, *b), c = [1, 2, 3], 4')
  end

  # --- ImplicitRestNode in nested multi-target (line 692) ---

  def test_multi_write_nested_implicit_rest
    assert_equal 'a,*,b=[1,2],3', @stage.call('(a,), b = [1, 2], 3')
  end

  # --- IndexTargetNode (lines 698-700) ---

  def test_multi_write_index_target
    assert_equal 'a[0],a[1]=1,2', @stage.call('a[0], a[1] = 1, 2')
  end

  # --- SplatNode in multi-target (line 702) ---

  def test_multi_write_splat_target
    assert_equal '*a=1,2', @stage.call('*a = 1, 2')
  end

  # --- Array pattern with rest (lines 713-716) ---

  def test_array_pattern_anonymous_rest
    assert_equal 'case x;in [1,*];:yes;end',
      @stage.call('case x; in [1, *]; :yes; end')
  end

  # --- Hash pattern with rest (lines 726-730) ---

  def test_hash_pattern_anonymous_splat
    assert_equal 'case x;in {a: 1,**};:yes;end',
      @stage.call('case x; in {a: 1, **}; :yes; end')
  end

  def test_hash_pattern_no_keywords
    assert_equal 'case x;in {a: 1,**nil};:yes;end',
      @stage.call('case x; in {a: 1, **nil}; :yes; end')
  end

  # --- ForwardingArgumentsNode (line 770) ---

  def test_forwarding_arguments
    assert_equal 'def f(...);g(...);end', @stage.call('def f(...); g(...); end')
  end

  # --- Multi-target param (line 787) ---

  def test_multi_target_param
    assert_equal 'def f((a,b));a+b;end', @stage.call('def f((a, b)); a + b; end')
  end

  # --- Post params (line 797) ---

  def test_post_params
    assert_equal 'def f(*a,b);end', @stage.call('def f(*a, b); end')
  end

  # --- NoKeywordsParameterNode (line 813) ---

  def test_no_keywords_param
    assert_equal 'def f(**nil);end', @stage.call('def f(**nil); end')
  end

  # --- ForwardingParameterNode (line 815) ---

  def test_forwarding_param
    assert_equal 'def f(...);end', @stage.call('def f(...); end')
  end

  # --- Nested multi-target param (line 832) ---

  def test_nested_multi_target_param
    assert_equal 'def f(((a,b),c));end', @stage.call('def f(((a, b), c)); end')
  end

  # --- Binary op separator for !~ (line 886) ---

  def test_not_match_separator
    assert_equal 'x !~/foo/', @stage.call('x !~ /foo/')
  end

  # --- Binary op separator for == after ?/! method (line 888) ---

  def test_eq_after_predicate_method
    assert_equal 'x.nil? ==true', @stage.call('x.nil? == true')
  end

  # --- Multi-statement parens (line 931) ---

  def test_multi_statement_parens
    assert_equal '(x;y)', @stage.call('(x; y)')
  end

  # The rebuild is the one stage that emits everything from scratch, so a node
  # type it does not know cannot be skipped — skipping deletes the code it
  # represents. New Ruby syntax must arrive as a loud failure, never as a
  # quietly smaller program.
  def test_unknown_node_raises_instead_of_dropping_code
    unknown = Object.new
    error = assert_raises(Ryac::MinifyError) { @stage.send(:r, unknown) }
    assert_equal 'Unknown node: Object', error.message
  end

  # --- Delimited positions take ranges bare ---

  def test_when_condition_range_is_bare
    assert_equal 'case x;when 0..10,20..;puts(1);end',
                 @stage.call("case x\nwhen (0..10), (20..) then puts 1\nend")
  end

  def test_splat_range_is_bare
    assert_equal 'a=[*1..2];p(*3..4)', @stage.call("a = [*(1..2)]\np(*(3..4))")
  end

  def test_argument_and_subscript_ranges_are_bare
    assert_equal 'f(1..2,k:3..);s[4..];h={a:5..6}',
                 @stage.call("f((1..2), k: (3..))\ns[(4..)]\nh = { a: (5..6) }")
  end

  def test_pinned_range_uses_the_pins_own_parens
    assert_equal 'case y;in ^(0..10);puts(1);end',
                 @stage.call("case y\nin ^((0..10)) then puts 1\nend")
  end

  def test_range_keeps_parens_outside_delimited_positions
    # Receiver and RHS positions still get the defensive parens.
    assert_equal 'puts((1..3).sum);r=(1..3)', @stage.call("puts (1..3).sum\nr = (1..3)")
  end

  # --- Flip-flops render structurally, not as a source slice ---

  def test_flipflop_compacts_interior_spacing
    assert_equal 'if (i==2)..(i==5);puts(i);end',
                 @stage.call('puts i if (i == 2)..(i == 5)')
  end

  # --- Floats take their shortest same-value spelling ---

  def test_float_exponent_spellings
    assert_equal 'p(15e2,5e-4,15e21,0.25,1.5,-3e1)',
                 @stage.call('p(1500.0, 0.0005, 1.5e+22, 0.25, 1.5, -30.0)')
  end

  # --- Percent arrays stay percent arrays when static ---

  def test_static_percent_arrays_render_canonically
    assert_equal 'a=%w[aa bb];b=%w[dd ee];c=%i[ff gg]',
                 @stage.call("a = %W[aa bb]\nb = %w(dd ee)\nc = %I[ff gg]")
  end

  def test_interpolating_percent_array_falls_back
    assert_equal 'x=1;a=["a#{x}","b"]', @stage.call("x = 1\na = %W[a\#{x} b]")
  end

  # --- and/or always render as the operator form ---

  def test_keyword_and_or_become_operators
    assert_equal 'a=1;if a&&a>0;puts(9);end;(b=a)||puts(8)',
                 @stage.call("a = 1\nputs 9 if a and a > 0\nb = a or puts 8")
  end

  def test_parenthesized_keyword_logic_keeps_its_value
    # z = (nil or 7) assigns 7; z = nil or 7 assigns nil. The operator form
    # needs no parens, so the value survives every position.
    assert_equal 'z=()||7;p(z)', @stage.call("z = (nil or 7)\np z")
    assert_equal 'p(1&&2)', @stage.call('p((1 and 2))')
  end

  def test_backslash_symbol_takes_the_quoted_form
    # `:$\` does not parse bare; the quoted form carries the raw spelling.
    assert_equal 'p(:"$\\\\")', @stage.call('p(:"$\\\\")')
    assert_equal 'a=[:x,:"$\\\\"]', @stage.call('a = %i[x $\\\\]')
  end

  def test_jump_with_value_keeps_parens_under_operator
    assert_equal 'def m(x);x&&(return 5);9;end',
                 @stage.call("def m(x); x and (return 5); 9; end")
    assert_equal 'def n(x);x&&return;9;end',
                 @stage.call("def n(x); x and return; 9; end")
  end
end
