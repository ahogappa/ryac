# frozen_string_literal: true

require_relative '../../../test_helper'

class TestIvarCollection < Minitest::Test
  include MinifyTestHelper

  # === L4 group: basic ivar renaming, attr-backed, dynamic access, inheritance ===

  L4_GROUP_CODE = [
    'class A;def initialize(v);@value=v;end;def get;@value;end;end;puts A.new(1).get',
    'class B;def initialize(a,b);@first=a;@second=b;end;def sum;@first+@second;end;end;puts B.new(1,2).sum',
    'class C;attr_reader :value;def initialize(v);@value=v;end;end;puts C.new(42).value',
    'class D;def initialize(v);@value=v;end;def check;defined?(@value);end;end;puts D.new(1).check',
    'class E;def initialize(v);@value=v;end;def get(name);instance_variable_get(name);end;end;puts E.new(1).get(:@value)',
    'class F;def initialize(v);@value=v;end;def set(name,v);instance_variable_set(name,v);end;def get;@value;end;end;puts F.new(1).get',
    'class G;def initialize;@count=0;end;def get;@count;end;end;class H<G;def inc;@count+=1;end;end;h=H.new;h.inc;puts h.get',
    'class I;attr_writer :value;def initialize(v);@value=v;end;def get;@value;end;end;puts I.new(1).get',
  ].join(';')

  L4_GROUP_EXPECTED =
    'class A;def initialize(a) =@a=a;def get =@a;end;puts A.new(1).get;' \
    'class B;def initialize(a,b) =(@b=a;@a=b);def sum =@b+@a;end;puts B.new(1,2).sum;' \
    'class C;attr :value;def initialize(a) =@value=a;end;puts C.new(42).value;' \
    'class D;def initialize(a) =@a=a;def check =defined?(@a);end;puts D.new(1).check;' \
    'class E;def initialize(a) =@value=a;def get(a) =instance_variable_get a;end;puts E.new(1).get(:"@value");' \
    'class F;def initialize(a) =@value=a;def set(a,b) =instance_variable_set a,b;def get =@value;end;puts F.new(1).get;' \
    'class G;def initialize =@a=0;def get =@a;end;class H<G;def inc =@a+=1;end;a=H.new;a.inc;puts a.get;' \
    'class I;attr_writer :value;def initialize(a) =@value=a;def get =@value;end;puts I.new(1).get'

  def l4_group
    @l4_group ||= minify_at_level(L4_GROUP_CODE, 4)
  end

  def test_ivar_renamed
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_multiple_ivars_renamed
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_attr_backed_ivar_not_renamed_at_l4
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_defined_ivar_renamed
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_dynamic_ivar_access_prevents_rename
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_instance_variable_set_prevents_rename
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_inherited_ivars_use_same_short_name
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  def test_attr_writer_backed_ivar_not_renamed
    assert_equal L4_GROUP_EXPECTED, l4_group.code
  end

  # === L5 group: attr coordinate renames ===

  L5_GROUP_CODE = [
    'class J;attr_reader :value;def initialize(v);@value=v;end;end;puts J.new(42).value',
    'class K;attr_accessor :value;def initialize(v);@value=v;end;end;k=K.new(42);k.value=10;puts k.value',
    'class L;attr_reader :value;def initialize(v);@value=v;end;def check;@value;end;end;puts L.new(42).check',
    'class M;attr_accessor :xy;def initialize(v);@xy=v;end;def check;xy;end;def set(v);self.xy=v;end;end;puts M.new(42).check',
  ].join(';')

  L5_GROUP_EXPECTED =
    'class J;attr :a;def initialize(a) =@a=a;end;puts J.new(42).a;' \
    'class K;attr :a,!!1;def initialize(a) =@a=a;end;a=K.new 42;a.a=10;puts a.a;' \
    'class L;attr :b;def initialize(a) =@b=a;def a =@b;end;puts L.new(42).a;' \
    'class M;attr :c,!!1;def initialize(a) =@c=a;def a =c;def set(a) =self.c=a;end;puts M.new(42).a'

  def l5_group
    @l5_group ||= minify_at_level(L5_GROUP_CODE, 5)
  end

  def test_attr_reader_renamed_at_l5
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_attr_accessor_renamed_at_l5
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_attr_path_b_ivar_driven_rename
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end

  def test_attr_path_b_getter_and_setter_call_site_rename
    assert_equal L5_GROUP_EXPECTED, l5_group.code
  end
end
