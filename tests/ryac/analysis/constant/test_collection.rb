# frozen_string_literal: true

require_relative '../../../test_helper'

class TestConstantCollection < Minitest::Test
  include MinifyTestHelper

  # === L2 group: most verify_output:true tests ===

  L2_GROUP_CODE = [
    'class Cc1;MY_CONST=42;def m;MY_CONST;end;end;puts Cc1.new.m',
    'module Cc2;module Cc3;VAL=1;end;end;puts Cc2::Cc3::VAL',
    'module Cc4;module Cc5;Cc4::Cc5::VAL=42;end;end;puts Cc4::Cc5::VAL',
    'class Cc6;BAR=99;def m;Cc6::BAR;end;end;puts Cc6.new.m',
    'MYVAL=42;puts ::MYVAL',
    'class Cc7;VAL=1;private_constant :VAL;def m;VAL;end;end;puts Cc7.new.m',
    'class Cc8;VAL=1;end;class Cc9<Cc8;def m;VAL;end;end;puts Cc9.new.m',
    'module Cc10;class Cc11;end;end;class Cc12<Cc10::Cc11;def m;1;end;end;puts Cc12.new.m',
    'class Cc13<StandardError;def m;1;end;end;puts Cc13.new.m',
    'class Cc14;VAL=42;def m;::Cc14::VAL;end;end;puts Cc14.new.m',
    'class Cc15;VAL=1;def m;VAL;end;end;puts Cc15.new.m;puts ARGV.size',
    'class Cc16;VAL=1;def m1;VAL;end;def m2;VAL;end;def m3;VAL;end;end;puts Cc16.new.m1;puts Cc16.new.m2;puts Cc16.new.m3',
  ].join(';')

  L2_GROUP_EXPECTED =
    'class Cc1;A=42;def m =A;end;puts Cc1.new.m;' \
    'module Cc2;module Cc3;E=1;end;end;puts Cc2::Cc3::E;' \
    'module Cc4;module Cc5;Cc4::Cc5::C=42;end;end;puts Cc4::Cc5::C;' \
    'class Cc6;I=99;def m =Cc6::I;end;puts Cc6.new.m;' \
    'D=42;puts D;' \
    'class Cc7;VAL=1;private_constant :VAL;def m =VAL;end;puts Cc7.new.m;' \
    'class Cc8;F=1;end;class Cc9<Cc8;def m =F;end;puts Cc9.new.m;' \
    'module Cc10;class Cc11;end;end;class Cc12<Cc10::Cc11;def m =1;end;puts Cc12.new.m;' \
    'class Cc13<StandardError;def m =1;end;puts Cc13.new.m;' \
    'class Cc14;G=42;def m =Cc14::G;end;puts Cc14.new.m;' \
    'class Cc15;H=1;def m =H;end;puts Cc15.new.m;puts ARGV.size;' \
    'class Cc16;B=1;def m1 =B;def m2 =B;def m3 =B;end;puts Cc16.new.m1;puts Cc16.new.m2;puts Cc16.new.m3'

  L2_GROUP_ALIASES_EXPECTED =
    'MYVAL=D;Cc1::MY_CONST=Cc1::A;Cc14::VAL=Cc14::G;Cc15::VAL=Cc15::H;' \
    'Cc16::VAL=Cc16::B;Cc6::BAR=Cc6::I;Cc8::VAL=Cc8::F;Cc2::Cc3::VAL=Cc2::Cc3::E;Cc4::Cc5::VAL=Cc4::Cc5::C'

  def l2_group
    @l2_group ||= minify_at_level(L2_GROUP_CODE, 2)
  end

  def test_value_constant_aliased
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_nested_module_constant_aliased
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_explicit_constant_path_write_inside_nested_module
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_qualified_constant_read_with_class_prefix
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_top_level_constant_reference
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_private_constant_not_aliased
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_class_with_superclass_constant
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_class_with_qualified_superclass
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_class_inheriting_from_stdlib
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_top_level_scope_prefix_constant_read
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_stdlib_constant_reference_alongside_user_constant
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  def test_multiple_constant_references_augmented
    assert_equal L2_GROUP_EXPECTED, l2_group.code
    assert_equal L2_GROUP_ALIASES_EXPECTED, l2_group.aliases
  end

  # === Standalone: non-overlapping scope (verify_output: false) ===

  def test_non_overlapping_scope_constant_path_write
    code = 'module Bar;end;module Foo;Bar::VAL=42;end;puts Bar::VAL'
    result = minify_at_level(code, 2, verify_output: false)
    assert_equal 'module Bar;end;module Foo;Foo::Bar::A=42;end;puts Bar::VAL', result.code
    assert_equal 'Foo::Bar::VAL=Foo::Bar::A', result.aliases
  end
end
