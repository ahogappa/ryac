# frozen_string_literal: true

require_relative '../../../test_helper'

class TestMethodCollection < Minitest::Test
  include MinifyTestHelper

  # === L5 group A: most verify_output:true tests ===

  L5_GROUP_A_CODE = [
    'class A;def greet_user;1;end;end;puts A.new.greet_user',
    'class B;attr_reader :current_value;def initialize(v);@current_value=v;end;end;puts B.new(1).current_value',
    'class C;attr_accessor :stored_value;def initialize(v);@stored_value=v;end;end;puts C.new(1).stored_value',
    'class D;end;def D.class_helper;42;end;puts D.class_helper',
    'class E;def compute;1;end;end;class F;def compute;2;end;end;def mc_run(obj);obj.compute;end;puts mc_run(E.new);puts mc_run(F.new)',
    'class G;def calculate;1;end;end;class H<G;def calculate;super+1;end;end;puts H.new.calculate',
    'module I;def helper_method;1;end;module_function :helper_method;end;puts I.helper_method',
    'class J;def greet_world;1;end;def check_j;respond_to?(:greet_world);end;end;puts J.new.check_j',
    'class K;def greet_friend;1;end;def check_k;method(:greet_friend);end;end;puts K.new.check_k.call',
    'class L;def public_method;private_method;end;private;def private_method;42;end;end;puts L.new.public_method',
    'class M;def original_method;1;end;alias aliased_method original_method;end;puts M.new.aliased_method',
    'class N;def long_name;1;end;end;class O;def work;long_name;end;end;puts N.new.long_name',
    'class P;def process_data;1;end;end;obj = Marshal.load(Marshal.dump(P.new));puts obj.process_data',
    'class Q;def size;42;end;end;puts [1,2,3].size;puts Q.new.size',
    'class R;def initialize(v);@v=v;end;def get;@v;end;end;puts R.new(1).get',
    'class S;def to_s;"F";end;end;puts S.new.to_s',
  ].join(';')

  L5_GROUP_A_EXPECTED =
    'class A;def a =1;end;puts A.new.a;' \
    'class B;attr :a;def initialize(a) =@a=a;end;puts B.new(1).a;' \
    'class C;attr :a,!!1;def initialize(a) =@a=a;end;puts C.new(1).a;' \
    'class D;end;def D.a =42;puts D.a;' \
    'class E;def a =1;end;class F;def a =2;end;def c(a) =a.a;puts c(E.new);puts c(F.new);' \
    'class G;def a =1;end;class H<G;def a =super+1;end;puts H.new.a;' \
    'module I;def helper_method =1;module_function :helper_method;end;puts I.helper_method;' \
    'class J;def greet_world =1;def a =respond_to?(:greet_world);end;puts J.new.a;' \
    'class K;def greet_friend =1;def a =method :greet_friend;end;puts K.new.a.call;' \
    'class L;def b =a;private;def a =42;end;puts L.new.b;' \
    'class M;def original_method =1;alias aliased_method original_method;end;puts M.new.aliased_method;' \
    'class N;def a =1;end;class O;def work =a;end;puts N.new.a;' \
    'class P;def process_data =1;end;a=Marshal.load Marshal.dump(P.new);puts a.process_data;' \
    'class Q;def a =42;end;puts [1,2,3].size;puts Q.new.a;' \
    'class R;def initialize(a) =@v=a;def a =@v;end;puts R.new(1).a;' \
    'class S;def to_s =?F;end;puts S.new.to_s'

  def l5_group_a
    @l5_group_a ||= minify_at_level(L5_GROUP_A_CODE, 5)
  end

  def test_def_method_collected_and_renamed
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_attr_reader_collected_and_renamed
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_attr_accessor_collected_and_renamed
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_def_on_constant_receiver_collected
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_polymorphic_calls_grouped
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_super_calls_merged_with_parent
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_module_function_not_renamed
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_respond_to_excludes_method
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_method_object_excludes_method
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_private_method_still_renamed
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_aliased_methods_not_renamed
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_unresolved_no_receiver_call_mapped
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_unresolved_receiver_call_excluded
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_unresolved_call_unrelated_to_defined_method
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_initialize_excluded
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  def test_to_s_excluded
    assert_equal L5_GROUP_A_EXPECTED, l5_group_a.code
  end

  # === Standalone: non-module constant receiver (needs NonExistent → A rename) ===

  def test_def_on_non_module_constant_receiver
    code = "NonExistent = Object.new\ndef NonExistent.long_method\n42\nend\nputs NonExistent.long_method"
    result = minify_at_level(code, 5)
    assert_equal 'A=Object.new;def A.long_method =42;puts A.long_method', result.code
  end

  # === Standalone: bare `module_function` ===

  # A bare `module_function` publishes each `def` as both an instance and a
  # singleton method. Both must receive the same short name, or the internal
  # call and the external `U.…` call end up pointing at different names.
  def test_bare_module_function_variants_share_a_name
    code = 'module U;module_function;def unwrap_value(n);n.is_a?(Array) ? n.first : n;end;' \
           'def string_like?(n);unwrap_value(n).is_a?(String);end;end;puts U.string_like?(["x"])'
    result = minify_at_level(code, 5)
    assert_equal 'module U;module_function;def b(a) =a.is_a?(Array)?a[0] : a;' \
                 'def a(a) =b(a).is_a?(String);end;puts U.a([?x])',
                 result.code
  end

  # === Standalone: undef (verify_output: false) ===

  def test_undef_methods_not_renamed
    code = 'class F;def original_method;1;end;undef :original_method;end'
    result = minify_at_level(code, 5, verify_output: false)
    assert_equal 'class F;def original_method =1;undef original_method;end', result.code
  end
end
