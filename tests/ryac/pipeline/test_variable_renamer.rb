# frozen_string_literal: true

require_relative '../../test_helper'

class TestVariableRenamer < Minitest::Test
  include MinifyTestHelper

  # === L3 group A: locals, params, blocks, for, assoc (verify_output: true) ===

  L3_GROUP_A_CODE = [
    'class V1;def m;value=1;puts value;value;end;end;V1.new.m',
    'class V2;def m;first,second=1,2;first+second;end;end;puts V2.new.m',
    'class V3;def m;count=0;count+=1;count||=0;count&&=1;count;end;end;puts V3.new.m',
    'class V4;def m(value,count);value+count;end;end;puts V4.new.m(1,2)',
    'class V5;def m(value=10);value;end;end;puts V5.new.m',
    'class V6;def m(*args);args.size;end;end;puts V6.new.m(1,2)',
    'class V7;def m(**opts);opts.size;end;end;puts V7.new.m(a:1)',
    'class V8;def m(&blk);blk.call;end;end;puts(V8.new.m{42})',
    'class V10;def m;[1,2].map{|item|item*2};end;end;puts V10.new.m.inspect',
    'class V11;def m;[1,2,3].select{|val,keep=true|keep};end;end;puts V11.new.m.inspect',
    'class V12;def m;total=0;for num in [1,2,3];total+=num;end;total;end;end;puts V12.new.m',
    'class V13;def m(value);{value:};end;end;puts V13.new.m(42).inspect',
  ].join(';')

  L3_GROUP_A_EXPECTED = 'class V1;def m =(a=1;puts a;a);end;V1.new.m;' \
    'class V2;def m;a,b=1,2;a+b;end;end;puts V2.new.m;' \
    'class V3;def m =(a=0;a+=1;a||=0;a&&=1;a);end;puts V3.new.m;' \
    'class V4;def m(a,b) =a+b;end;puts V4.new.m(1,2);' \
    'class V5;def m(a=10) =a;end;puts V5.new.m;' \
    'class V6;def m(*a) =a.size;end;puts V6.new.m(1,2);' \
    'class V7;def m(**a) =a.size;end;puts V7.new.m(a:1);' \
    'class V8;def m(&a) =a.();end;puts(V8.new.m{42});' \
    'class V10;def m =[1,2].map{_1*2};end;puts V10.new.m.inspect;' \
    'class V11;def m =[1,2,3].select{|a,b=true|b};end;puts V11.new.m.inspect;' \
    'class V12;def m =(a=0;for b in [1,2,3];a+=b;end;a);end;puts V12.new.m;' \
    'class V13;def m(a) ={value:a};end;puts V13.new.m(42).inspect'

  def l3_group_a
    @l3_group_a ||= minify_at_level(L3_GROUP_A_CODE, 3)
  end

  def test_local_read_and_write
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_local_multi_assign_target
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_local_operator_writes
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_def_positional_params
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_def_optional_param
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_def_rest_param
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_def_double_splat_param
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_def_block_param
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_block_params_numbered
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_block_params_with_optional
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_for_node_index_renamed
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_assoc_shorthand_expanded_when_renamed
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  # === Keyword renamed (standalone - sensitive to grouping context) ===

  def test_keyword_renamed
    code = 'class F;def m(label:);label;end;end;puts F.new.m(label:"x")'
    result = minify_at_level(code, 3)
    assert_equal 'class F;def m(a:) =a;end;puts F.new.m(a:?x)', result.code
  end

  # An unresolved call sharing the method's name poisons its keyword renames
  # only when it actually writes keywords — a keyword-less call is untouched
  # by the rename no matter which method it reaches. Object.const_get keeps
  # the receiver opaque to inference, so `x.walk(3)` is genuinely unresolved.
  def test_keyword_renamed_despite_unresolved_keywordless_namesake
    code = 'class T;def walk(node,depth:);node.is_a?(Array) ? node.sum{|c|walk(c,depth:depth+1)}:depth;end;end;' \
           'class L;def walk(steps);steps;end;end;' \
           'x=Object.const_get(:L).new;puts x.walk(3);puts T.new.walk([[1],2],depth:0)'
    result = minify_at_level(code, 3)
    assert_equal 'class T;def walk(b,a:) =b.is_a?(Array)?b.sum{walk _1,a:a+1}:a;end;' \
                 'class L;def walk(a) =a;end;' \
                 'a=Object.const_get(:L).new;puts a.walk(3);puts T.new.walk([[1],2],a:0)',
                 result.code
  end

  # ...while a keyword-writing unresolved call still disqualifies the name.
  def test_keyword_kept_when_unresolved_call_writes_keywords
    code = 'class T;def walk(node,depth:);depth;end;end;' \
           'x=Object.const_get(:T).new;puts x.walk(1,depth:5)'
    result = minify_at_level(code, 3)
    assert_equal 'class T;def walk(a,depth:) =depth;end;' \
                 'a=Object.const_get(:T).new;puts a.walk(1,depth:5)',
                 result.code
  end

  # === L4 group: ivars, cvars, gvars, multi-assign (verify_output: true) ===

  L4_GROUP_CODE = [
    'class B;def initialize(v);@value=v;end;def g;@value;end;end;puts B.new(1).g',
    'class C;def initialize;@count=0;end;def m;@count+=1;@count;end;end;a=C.new;a.m;puts a.m',
    'class D;@@count=0;def initialize;@@count+=1;end;def self.count;@@count;end;end;D.new;puts D.count',
    'class E;def m;$vr_global=42;$vr_global;end;end;puts E.new.m',
    'class G;def m;a,@value=1,2;@value;end;end;puts G.new.m',
    'class H;def m;a,@@value=1,2;@@value;end;end;puts H.new.m',
    'class I;def m;a,$vr_val=1,2;$vr_val;end;end;puts I.new.m',
  ].join(';')

  L4_GROUP_EXPECTED = 'class B;def initialize(a) =@a=a;def g =@a;end;puts B.new(1).g;' \
    'class C;def initialize =@a=0;def m =(@a+=1;@a);end;a=C.new;a.m;puts a.m;' \
    'class D;@@a=0;def initialize =@@a+=1;def self.a =@@a;end;D.new;puts D.a;' \
    'class E;def m =($a=42;$a);end;puts E.new.m;' \
    'class G;def m;a,@a=1,2;@a;end;end;puts G.new.m;' \
    'class H;def m;a,@@a=1,2;@@a;end;end;puts H.new.m;' \
    'class I;def m;a,$b=1,2;$b;end;end;puts I.new.m'

  def l4_group
    @l4_group ||= minify_at_level(L4_GROUP_CODE, 4)
  end

  def test_ivar_read_write
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_ivar_operator_write
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_cvar_read_write
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_gvar_read_write
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_ivar_multi_assign_target
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_cvar_multi_assign_target
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_gvar_multi_assign_target
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  # === L3 not-renamed group (verify_output: true) ===

  L3_NOT_RENAMED_CODE = [
    'class J;def initialize(v);@value=v;end;def g;@value;end;end;puts J.new(1).g',
    'class K;def m;$my_global=42;$my_global;end;end;puts K.new.m',
  ].join(';')

  L3_NOT_RENAMED_EXPECTED = 'class J;def initialize(a) =@value=a;def g =@value;end;puts J.new(1).g;' \
    'class K;def m =($my_global=42;$my_global);end;puts K.new.m'

  def l3_not_renamed_group
    @l3_not_renamed_group ||= minify_at_level(L3_NOT_RENAMED_CODE, 3)
  end

  def test_ivar_not_renamed_at_l3
    assert_equal L3_NOT_RENAMED_EXPECTED, l3_not_renamed_group.code
  end

  def test_gvar_not_renamed_at_l3
    assert_equal L3_NOT_RENAMED_EXPECTED, l3_not_renamed_group.code
  end

  # === Post parameters + keyword shorthand (L3) ===

  def post_param_and_keyword_shorthand_group
    @post_param_and_keyword_shorthand_group ||= minify_at_level(
      'class F;def m(*rest,last);last;end;def n(label:);q(label:);end;def q(label:);label;end;end;puts F.new.m(1,2,3);puts F.new.n(label:"x")', 3
    )
  end

  def test_post_param_renamed
    result = post_param_and_keyword_shorthand_group
    assert_equal 'class F;def m(*a,b) =b;def n(a:) =q(a:);def q(a:) =a;end;puts F.new.m(1,2,3);puts F.new.n(a:?x)', result.code
  end

  # === Named captures + keyword shorthand (L3) ===

  L3_MATCH_WRITE_CODE = [
    'class M;def m(str);/(?<name>\w+)/ =~ str;name;end;end;puts M.new.m("hello")',
    'class N;def label;"x";end;def m;n(label:);end;def n(label:);label;end;end;puts N.new.m',
  ].join(';')

  # `name` is written by the regex group and must keep its name on the read
  # side too, and `n(label:)` puns on METHOD label — renaming either half
  # once produced NameErrors this group could only pin with verification off.
  L3_MATCH_WRITE_EXPECTED = 'class M;def m(a) =(/(?<name>\w+)/=~a;name);end;puts M.new.m("hello");' \
    'class N;def label =?x;def m =n(label:);def n(label:) =label;end;puts N.new.m'

  def l3_match_write_group
    @l3_match_write_group ||= minify_at_level(L3_MATCH_WRITE_CODE, 3)
  end

  def test_match_write_node_walk
    assert_equal L3_MATCH_WRITE_EXPECTED, l3_match_write_group.code
  end

  def test_implicit_method_in_keyword_arg
    assert_equal L3_MATCH_WRITE_EXPECTED, l3_match_write_group.code
  end

  # === Duplicated argument name regression ===

  def test_no_duplicated_argument_names_from_var_hints
    code = 'class A;def m(a:);a;end;end;def f(x,y);A.new.m(a:x);A.new.m(a:y);end;puts f(1,2)'
    result = minify_at_level(code, 3)
    assert_equal 'class A;def m(a:) =a;end;def f(a,b) =(A.new.m(a:);A.new.m(a:b));puts f(1,2)', result.code
  end

  def test_no_duplicated_argument_names_from_underscore_block_params
    code = '[1].map{|_,b,_,_|b}'
    result = minify_at_level(code, 3)
    assert_equal '[1].map{|_,a,_,_|a}', result.code
  end

  def test_underscore_prefixed_block_params_are_renamed
    code = '[1].map{|_a,b|b+_a}'
    result = minify_at_level(code, 3)
    assert_equal '[1].map{_2+_1}', result.code
  end
end
