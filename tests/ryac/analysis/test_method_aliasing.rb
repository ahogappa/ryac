# frozen_string_literal: true

require_relative '../../test_helper'

class TestMethodAliasing < Minitest::Test
  include MinifyTestHelper

  # === L5 group: all verify_output:true tests ===

  L5_GROUP_CODE = [
    'class A;def m(a);a.length;end;end;puts A.new.m([1,2])',
    'class B;def m(a);a.first;end;end;puts B.new.m([10,20])',
    'class C;def m(a);a.last;end;end;puts C.new.m([10,20])',
    'class D;def m(a);a.first(2);end;end;p D.new.m([10,20,30])',
    'def ma_f;raise "x";end;ma_f rescue puts "ok"',
    'class E;def m(a);a.collect{|x|x+1};end;end;p E.new.m([1,2])',
    'class F;def m(n);n.zero?;end;end;puts F.new.m(0)',
    'class G;def m(a);a.empty?;end;end;puts G.new.m([])',
    'class H;def m(s);s.empty?;end;end;puts H.new.m("")',
    'class I;def m(h);h.empty?;end;end;puts I.new.m({})',
  ].join(';')

  L5_GROUP_EXPECTED =
    'class A;def m(a) =a.size;end;puts A.new.m([1,2]);' \
    'class B;def m(a) =a[0];end;puts B.new.m([10,20]);' \
    'class C;def m(a) =a.last;end;puts C.new.m([10,20]);' \
    'class D;def m(a) =a.first 2;end;p D.new.m([10,20,30]);' \
    'def a =fail ?x;(a rescue puts("ok"));' \
    'class E;def m(a) =a.map{_1+1};end;p E.new.m([1,2]);' \
    'class F;def m(a) =a==0;end;puts F.new.m(0);' \
    'class G;def m(a) =a==[];end;puts G.new.m([]);' \
    'class H;def m(a) =a=="";end;puts H.new.m("");' \
    'class I;def m(a) =a=={};end;puts I.new.m({})'

  def l5_group
    @l5_group ||= minify_at_level(L5_GROUP_CODE, 5)
  end

  def test_length_to_size
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_first_to_index_zero
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_last_not_transformed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_first_with_argument_not_transformed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_raise_to_fail
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_collect_to_map
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_zero_check_to_equality
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_empty_array_to_equality
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_empty_string_to_equality
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_empty_hash_to_equality
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end
end
