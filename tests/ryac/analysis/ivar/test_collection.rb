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

  # Resolvable methods rename under the stable :safe policy — except F#set,
  # which no resolved call reaches, so its name survives as public surface.
  L4_GROUP_EXPECTED =
    'class A;def initialize(a) =@a=a;def a =@a;end;puts A.new(1).a;' \
    'class B;def initialize(a,b) =(@b=a;@a=b);def a =@b+@a;end;puts B.new(1,2).a;' \
    'class C;attr :value;def initialize(a) =@value=a;end;puts C.new(42).value;' \
    'class D;def initialize(a) =@a=a;def a =defined?(@a);end;puts D.new(1).a;' \
    'class E;def initialize(a) =@value=a;def a(a) =instance_variable_get a;end;puts E.new(1).a(:@value);' \
    'class F;def initialize(a) =@value=a;def set(a,b) =instance_variable_set a,b;def a =@value;end;puts F.new(1).a;' \
    'class G;def initialize =@a=0;def a =@a;end;class H<G;def b =@a+=1;end;a=H.new;a.b;puts a.a;' \
    'class I;attr_writer :value;def initialize(a) =@value=a;def a =@value;end;puts I.new(1).a'

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

  # L declares `attr_reader :value` but nothing calls L's getter — inference
  # sees a def with no call sites. J's and K's `value` getters are called, so
  # the mid is renamed; the blind-def lockstep rule pulls L's getter into the
  # same group, and `a` lands on all three declarations.
  L5_GROUP_EXPECTED =
    'class J;attr :a;def initialize(a) =@a=a;end;puts J.new(42).a;' \
    'class K;attr :a,!!1;def initialize(a) =@a=a;end;a=K.new 42;a.a=10;puts a.a;' \
    'class L;attr :a;def initialize(a) =@a=a;def b =@a;end;puts L.new(42).b;' \
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

  # === Latent-path safety: sites inference cannot see must pin the symbol ===
  #
  # A setter or getter call inside a never-invoked method is invisible to
  # type inference (nothing types the receiver), and attr_accessor's setter
  # def is derived from the declared symbol rather than registered as a
  # method. Renaming the declaration would strand such a site on the old
  # name — a NoMethodError that only fires the first time the dead path
  # actually runs. The declaration must keep its symbols instead.

  def test_attr_with_hidden_setter_site_not_renamed
    code = 'class Config;attr_accessor :timeout_ms;def initialize;@timeout_ms=100;end;end;' \
           'class Tuner;def bump(target);target.timeout_ms=500;end;end;puts Config.new.timeout_ms'
    result = minify_at_level(code, 5)
    assert_equal 'class A;attr :timeout_ms,!!1;def initialize =@timeout_ms=100;end;' \
                 'class B;def bump(a) =a.timeout_ms=500;end;puts A.new.timeout_ms',
                 result.code
  end

  def test_attr_with_hidden_getter_site_not_renamed
    code = 'class Config;attr_reader :timeout_ms;def initialize;@timeout_ms=100;end;end;' \
           'class Reporter;def show(target);puts target.timeout_ms;end;end;puts Config.new.timeout_ms'
    result = minify_at_level(code, 5)
    assert_equal 'class A;attr :timeout_ms;def initialize =@timeout_ms=100;end;' \
                 'class B;def show(a) =puts a.timeout_ms;end;puts A.new.timeout_ms',
                 result.code
  end

  def test_attr_with_hidden_operator_write_not_renamed
    code = 'class Counter;attr_accessor :hit_count;def initialize;@hit_count=0;end;end;' \
           'class Driver;def punch(target);target.hit_count+=7;end;end;puts Counter.new.hit_count'
    result = minify_at_level(code, 5)
    assert_equal 'class A;attr :hit_count,!!1;def initialize =@hit_count=0;end;' \
                 'class B;def punch(a) =a.hit_count+=7;end;puts A.new.hit_count',
                 result.code
  end

  # attr_writer never renames its declaration, so a reader sharing its
  # symbol must not rename either: the writer-defined setter would keep
  # assigning the original ivar while the renamed reader reads the new one —
  # silently wrong values, not even an error.
  def test_attr_reader_sharing_attr_writer_symbol_not_renamed
    code = 'class Pack;attr_reader :payload_data;attr_writer :payload_data;def initialize;@payload_data=1;end;end;' \
           'pack=Pack.new;pack.payload_data=9;puts pack.payload_data'
    result = minify_at_level(code, 5)
    assert_equal 'class A;attr :payload_data;attr_writer :payload_data;' \
                 'def initialize =@payload_data=1;end;' \
                 'a=A.new;a.payload_data=9;puts a.payload_data',
                 result.code
  end

# === Reflection aimed at another object: the slot lives in its class ===
#
# A receiverless reflection call reaches its own class; one written with
# a receiver reaches whatever that receiver is. A literal name keeps its
# spelling everywhere, so no receiver type is needed for it. A computed
# name excludes the receiver's class family when inference knows the
# receiver, and every ivar when it does not — an Object could be an
# instance of any class the program defines.

def test_literal_name_through_another_object_keeps_the_slot
  code = 'class Ext;def initialize;@other=:wrong;@raw_node=:prism;end;end;' \
         'class Oracle;def self.via_get(node);node.instance_variable_get(:@raw_node);end;end;' \
         'p Oracle.via_get(Ext.new)'
  result = minify_at_level(code, 5)
  assert_equal 'class B;def initialize =(@a=:wrong;@raw_node=:prism);end;' \
               'class A;def self.a(a) =a.instance_variable_get :@raw_node;end;p A.a(B.new)',
               result.code
end

# The block runs with the other object as self, so its ivar is that
# object's. Renamed under the class the text sits in, it would read
# whichever of the other class's ivars landed on the same short name.
def test_instance_eval_block_on_another_object_keeps_its_ivars
  code = 'class Ext;def initialize;@other=:wrong;@raw_node=:prism;end;def bump;@other=@other.to_s;@other;end;end;' \
         'class Oracle;def self.via_block(node);node.instance_eval{@raw_node};end;end;' \
         'p Oracle.via_block(Ext.new)'
  result = minify_at_level(code, 5)
  assert_equal 'class B;def initialize =(@a=:wrong;@raw_node=:prism);def bump =(@a=@a.to_s;@a);end;' \
               'class A;def self.a(node) =node.instance_eval{@raw_node};end;p A.a(B.new)',
               result.code
end

def test_computed_name_through_a_known_receiver_excludes_its_class_only
  code = 'class Ext;def initialize;@other=1;@raw_node=2;end;end;' \
         'class Plain;def initialize;@long_name=3;end;def get;@long_name;end;end;' \
         'class Dumper;def self.dump(o);o.instance_variables;end;end;' \
         'p Dumper.dump(Ext.new),Plain.new.get'
  result = minify_at_level(code, 5)
  assert_equal 'class C;def initialize =(@other=1;@raw_node=2);end;' \
               'class B;def initialize =@a=3;def a =@a;end;' \
               'class A;def self.a(a) =a.instance_variables;end;p A.a(C.new),B.new.a',
               result.code
end

def test_computed_name_through_an_unknown_receiver_excludes_every_ivar
  code = 'class Plain;def initialize;@long_name=3;end;def get;@long_name;end;end;' \
         'class Dumper;def self.dump(o);o.instance_variables;end;end;' \
         'p Dumper.dump(Object.new),Plain.new.get'
  result = minify_at_level(code, 5)
  assert_equal 'class B;def initialize =@long_name=3;def a =@long_name;end;' \
               'class A;def self.a(a) =a.instance_variables;end;p A.a(Object.new),B.new.a',
               result.code
end

# A class object is a receiver like any other: the computed name reaches
# its class-level ivars.
def test_computed_name_on_a_class_object_keeps_its_class_level_ivars
  code = 'class Registry;@entries=[];def self.entries;@entries;end;end;' \
         'class Dumper;def self.dump(k);k.instance_variables;end;end;' \
         'p Dumper.dump(Registry),Registry.entries'
  result = minify_at_level(code, 5)
  assert_equal 'class A;@entries=[];def self.a =@entries;end;' \
               'class B;def self.a(a) =a.instance_variables;end;p B.a(A),A.a',
               result.code
end

# A literal name pins that name alone; the class's other ivars still
# rename.
def test_literal_name_on_self_pins_only_that_name
  code = 'class Config;def initialize;instance_variable_set(:@romfile_path,"game.nes");@frame_count=0;end;' \
         'def tick;@frame_count+=1;end;def path;@romfile_path;end;end;' \
         'c=Config.new;c.tick;p c.path,c.tick'
  result = minify_at_level(code, 5)
  assert_equal 'class A;def initialize =(instance_variable_set :@romfile_path,"game.nes";@a=0);' \
               'def a =@a+=1;def b =@romfile_path;end;a=A.new;a.a;p a.b,a.a',
               result.code
end

# === A computed name on self reaches the whole class family ===
#
# An instance carries the slots every ancestor's methods write, and every
# descendant's instances run the access written in the base — so the
# exclusion covers both directions, not just the class the text sits in.

def test_computed_name_in_a_subclass_keeps_the_ancestors_slot
  code = 'class Base;def initialize;@count=1;end;end;' \
         'class Child<Base;def peek(name);instance_variable_get(name);end;end;' \
         'p Child.new.peek(:@count)'
  result = minify_at_level(code, 5)
  assert_equal 'class B;def initialize =@count=1;end;class A<B;def a(a) =instance_variable_get a;end;p A.new.a(:@count)',
               result.code
end

def test_computed_name_in_a_base_class_keeps_the_descendants_slots
  code = 'class Base;def dump;instance_variables;end;end;' \
         'class Child<Base;def initialize;@extra_value=1;end;end;' \
         'class Plain;def initialize;@long_name=3;end;def get;@long_name;end;end;' \
         'p Child.new.dump,Plain.new.get'
  result = minify_at_level(code, 5)
  assert_equal 'class C;def a =instance_variables;end;class A<C;def initialize =@extra_value=1;end;' \
               'class B;def initialize =@a=3;def a =@a;end;p A.new.a,B.new.a',
               result.code
end
end
