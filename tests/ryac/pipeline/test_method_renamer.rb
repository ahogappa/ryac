# frozen_string_literal: true

require_relative '../../test_helper'

class TestMethodRenamer < Minitest::Test
  include MinifyTestHelper

  # A private helper from an included module and a public method inherited
  # from a superclass meet in the includer's namespace: give both the same
  # short name and the private helper shadows the public method for every
  # dispatch through the base. The allocator must keep them apart.
  def test_inherited_public_and_module_private_do_not_share_a_name
    code = <<~RUBY
      module PatchHelper
        private

        def patch_entry(value)
          value + 1
        end
      end

      class BaseStage
        def analysis_flag
          false
        end
      end

      class AliasStage < BaseStage
        include PatchHelper

        def build_result
          patch_entry(1)
        end
      end

      list = [BaseStage.new, AliasStage.new]
      list.each { |s| puts s.analysis_flag }
      puts AliasStage.new.build_result
    RUBY
    minify_at_level(code, 5)
  end

  # The compactor writes `ready_now? ==` with a protective space; once the
  # rename drops the ?, the space must not survive it — a re-minified
  # artifact would remove it and the self-host fixed point drifts.
  def test_question_mark_rename_consumes_protective_space
    code = "class Q;def ready_now?;true;end;end;q=Q.new;puts q.ready_now? == q.ready_now?\n"
    result = minify_at_level(code, 5)
    assert_equal 'class Q;def a =!!1;end;a=Q.new;puts a.a==a.a', result.code
  end

  # === L5 group: most verify_output:true tests ===

  L5_GROUP_CODE = [
    'class A;def greet_user;1;end;end;puts A.new.greet_user',
    'class B;def greet_user;1;end;end;b=B.new;puts b.greet_user',
    'class C;def greet_user;1;end;def use_it;greet_user;end;end;puts C.new.use_it',
    'class D;def subtract_number(x);x-1;end;alias neg subtract_number;end;d=D.new;puts d.neg(5)',
    'class E;attr_reader :current_value;def initialize(v);@current_value=v;end;end;puts E.new(42).current_value',
    'class F;attr_accessor :label;def initialize(v);@label=v;end;end;f=F.new("x");puts f.label',
    'class G;def m(arr);!arr.empty?;end;end;puts G.new.m([1])',
    'class H;def greet_friend;"hi";end;def m;send(:greet_friend);end;end;puts H.new.m',
    'class I;def initialize(v);@v=v;end;def get;@v;end;end;puts I.new(1).get',
    'class J;def to_s;"F";end;end;puts J.new.to_s',
    'class K;attr_accessor :foo_bar,:baz_qux;def initialize;@foo_bar=1;@baz_qux=2;end;end;k=K.new;puts k.foo_bar;puts k.baz_qux',
    'class L;def m(a);a.empty? ? "y" : "n";end;end;puts L.new.m([])',
  ].join(';')

  L5_GROUP_EXPECTED =
    'class A;def a =1;end;puts A.new.a;' \
    'class B;def a =1;end;a=B.new;puts a.a;' \
    'class C;def a =1;def b =a;end;puts C.new.b;' \
    'class D;def subtract_number(a) =a-1;alias neg subtract_number;end;b=D.new;puts b.neg(5);' \
    'class E;attr :a;def initialize(a) =@a=a;end;puts E.new(42).a;' \
    'class F;attr :a,!!1;def initialize(a) =@a=a;end;c=F.new ?x;puts c.a;' \
    'class G;def m(a) =a!=[];end;puts G.new.m([1]);' \
    'class H;def a ="hi";def m =send :a;end;puts H.new.m;' \
    'class I;def initialize(a) =@v=a;def a =@v;end;puts I.new(1).a;' \
    'class J;def to_s =?F;end;puts J.new.to_s;' \
    'class K;attr_accessor :a,:b;def initialize =(@a=1;@b=2);end;d=K.new;puts d.a;puts d.b;' \
    'class L;def m(a) =a==[]??y:?n;end;puts L.new.m([])'

  def l5_group
    @l5_group ||= minify_at_level(L5_GROUP_CODE, 5)
  end

  def test_def_name_renamed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_receiver_call_site_renamed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_implicit_receiver_call_site_renamed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_alias_not_renamed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_attr_reader_rewritten
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_attr_accessor_single_rewritten
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_negated_empty_to_not_eq_array
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_send_symbol_patched
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_initialize_not_renamed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_to_s_not_renamed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_attr_accessor_multiple_args_rewritten
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_empty_ternary_space_consumed
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  # === Call operator write group ===

  def call_operator_write_group
    @call_operator_write_group ||= minify_at_level(
      'class F;def val;@v;end;def val=(v);@v=v;end;def count;@c;end;def count=(v);@c=v;end;' \
      'def op_add;self.count+=1;end;def op_or;self.val||=42;end;def op_and;self.val&&=nil;end;' \
      'def initialize;@c=0;@v=nil;end;end;f=F.new;f.op_add;puts f.count;f.op_or;puts f.val;f.op_and;puts f.val.inspect',
      5
    )
  end

  # `self.count += 1` is one call site reading `count` and writing `count=`,
  # so renaming the pair requires their short names to stay textually linked
  # (`x` and `x=`), which independent allocation cannot promise. The previous
  # behavior renamed them independently anyway and emitted a setter def with
  # no `=` alongside a compound write to a now-nonexistent accessor — output
  # so broken this group had to run with verify_output: false. Accessors used
  # in compound writes now keep their names, the ordinary methods still
  # rename, and the output runs.
  def test_call_operator_write_keeps_accessor_pairs
    result = call_operator_write_group
    assert_equal 'class F;def val =@v;def val=(a);@v=a;end;def count =@c;def count=(a);@c=a;end;' \
      'def a =self.count+=1;def c =self.val||=42;def b =self.val&&=nil;' \
      'def initialize =(@c=0;@v=nil);end;a=F.new;a.a;puts a.count;a.c;puts a.val;a.b;puts a.val.inspect',
      result.code
  end
end
