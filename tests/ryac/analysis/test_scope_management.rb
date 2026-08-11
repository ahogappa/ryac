# frozen_string_literal: true

require_relative '../../test_helper'

class TestScopeManagement < Minitest::Test
  include MinifyTestHelper

  # === L3 group A: most verify_output:true tests ===

  L3_GROUP_A_CODE = [
    'value=42;puts value',
    'class Sc1;def m;x=1;y=2;x+y;end;end;puts Sc1.new.m',
    'class Sc2;def m;x=1;[1].each{|item|puts item+x};end;end;Sc2.new.m',
    'class Sc3;def m;[1].each{|outer|[2].each{|inner|puts outer+inner}};end;end;Sc3.new.m',
    'class Sc4;def m;[1,2].map{|item|item*2};end;end;puts Sc4.new.m.inspect',
    'class Sc5;def m;name="hello";eval("puts name");end;end;Sc5.new.m',
    'class Sc6;def m;begin;1/0;rescue ZeroDivisionError=>e;0;end;end;end;puts Sc6.new.m',
    'class Sc7;def m;begin;1/0;rescue ZeroDivisionError=>err;puts err.message;0;end;end;end;Sc7.new.m',
    'class Sc8;def m;{[:a,1]=>"x"}.each{|(sym,num),label|puts sym};end;end;Sc8.new.m',
    'class Sc9;def m;fn=->(val){val*2};fn.call(21);end;end;puts Sc9.new.m',
    'class Sc10;def m;secret=42;binding;end;end;Sc10.new.m',
    'class Sc11;def m;[1,2,3].each{|first,*rest|puts first};end;end;Sc11.new.m',
    'class Sc12;def m;proc{|a,b=1|a+b}.(2);end;end;puts Sc12.new.m',
    'class Sc13;def m;[1].each{|x,&blk|puts x};end;end;Sc13.new.m',
    'class Sc14;def m;[1].map{|x|x=x+1;x};end;end;puts Sc14.new.m.inspect',
    'class Sc15;def m;[[1,2]].map{|a,b|a};end;end;puts Sc15.new.m.inspect',
    'class Sc16;def m(x:,y: 0);x+y;end;end;puts Sc16.new.m(x: 1,y: 2)',
    'class Sc17;def m;{[1,[2,3]]=>4}.each{|(a,(b,c)),d|puts b};end;end;Sc17.new.m',
    'class Sc18;def m;{[1,2,3]=>4}.each{|(a,*b),c|puts a};end;end;Sc18.new.m',
    'class Sc19;def foo(long_name:);long_name;end;def bar;long_name=1;foo(long_name: long_name);end;end;puts Sc19.new.bar',
  ].join(';')

  L3_GROUP_A_EXPECTED =
    'value=42;puts value;' \
    'class Sc1;def m =(a=1;b=2;a+b);end;puts Sc1.new.m;' \
    'class Sc2;def m =(a=1;[1].each{puts _1+a});end;Sc2.new.m;' \
    'class Sc3;def m =[1].each{|a|[2].each{puts a+_1}};end;Sc3.new.m;' \
    'class Sc4;def m =[1,2].map{_1*2};end;puts Sc4.new.m.inspect;' \
    'class Sc5;def m =(name="hello";eval "puts name");end;Sc5.new.m;' \
    'class Sc6;def m =begin;1/0;rescue ZeroDivisionError;0;end;end;puts Sc6.new.m;' \
    'class Sc7;def m =begin;1/0;rescue ZeroDivisionError=>a;puts a.message;0;end;end;Sc7.new.m;' \
    'class Sc8;def m ={[:a,1]=>?x}.each{|(b,c),a|puts b};end;Sc8.new.m;' \
    'class Sc9;def m =(a=->(val){val*2};a.(21));end;puts Sc9.new.m;' \
    'class Sc10;def m =(secret=42;binding);end;Sc10.new.m;' \
    'class Sc11;def m =[1,2,3].each{|b,*a|puts b};end;Sc11.new.m;' \
    'class Sc12;def m =proc{|a,b=1|a+b}.(2);end;puts Sc12.new.m;' \
    'class Sc13;def m =[1].each{|b,&a|puts b};end;Sc13.new.m;' \
    'class Sc14;def m =[1].map{|a|a=a+1;a};end;puts Sc14.new.m.inspect;' \
    'class Sc15;def m =[[1,2]].map{|a,b|a};end;puts Sc15.new.m.inspect;' \
    'class Sc16;def m(x:,y:0) =x+y;end;puts Sc16.new.m(x:1,y:2);' \
    'class Sc17;def m ={[1,[2,3]]=>4}.each{|(b,(c,d)),a|puts c};end;Sc17.new.m;' \
    'class Sc18;def m ={[1,2,3]=>4}.each{|(b,*c),a|puts b};end;Sc18.new.m;' \
    'class Sc19;def foo(a:) =a;def bar =(a=1;foo(a:));end;puts Sc19.new.bar'

  def l3_group_a
    @l3_group_a ||= minify_at_level(L3_GROUP_A_CODE, 3)
  end

  def test_top_level_variables_renamed
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_method_local_variables_renamed
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_block_avoids_parent_names
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_nested_blocks
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_single_param_block_uses_numbered
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_eval_prevents_renaming
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_unused_rescue_variable_removed
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_used_rescue_variable_renamed
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_multi_target_block_params
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_lambda_params_renamed
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_binding_prevents_renaming
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_block_with_rest_param
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_block_with_optional_param
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_block_with_block_param
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_numbered_params_not_used_when_param_reassigned
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_numbered_params_not_used_when_trailing_param_unused
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_method_with_keyword_params
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_nested_multi_target_block_params
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_splat_in_multi_target_block_params
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  def test_var_hints_aligns_local_with_keyword
    assert_equal L3_GROUP_A_EXPECTED, l3_group_a.code
  end

  # === L3 verify_output:false group ===

  L3_NO_VERIFY_CODE = [
    'class Sf1;def m;val=10;local_variable_get(:val);end;end;Sf1.new.m',
    'class Sf2;def m;{a: 1}.each{|key:,**rest|puts key};end;end;Sf2.new.m',
    'class Sf3;def m;[1].each{|_1|puts _1};end;end;Sf3.new.m',
  ].join(';')

  L3_NO_VERIFY_EXPECTED =
    'class Sf1;def m =(val=10;local_variable_get :val);end;Sf1.new.m;' \
    'class Sf2;def m ={a:1}.each{|a:,**b|puts a};end;Sf2.new.m;' \
    'class Sf3;def m =[1].each{puts _1};end;Sf3.new.m'

  def l3_no_verify_group
    @l3_no_verify_group ||= minify_at_level(L3_NO_VERIFY_CODE, 3, verify_output: false)
  end

  def test_local_variable_get_prevents_renaming
    assert_equal L3_NO_VERIFY_EXPECTED, l3_no_verify_group.code
  end

  def test_block_with_keyword_param
    assert_equal L3_NO_VERIFY_EXPECTED, l3_no_verify_group.code
  end

  def test_existing_numbered_params_preserved
    assert_equal L3_NO_VERIFY_EXPECTED, l3_no_verify_group.code
  end
end
