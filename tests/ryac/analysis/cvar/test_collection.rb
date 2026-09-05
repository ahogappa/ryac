# frozen_string_literal: true

require_relative '../../../test_helper'

class TestCvarCollection < Minitest::Test
  include MinifyTestHelper

  # === Basic cvar collection and renaming ===

  def test_cvar_renamed
    code = 'class F;@@total=0;def initialize;@@total+=1;end;def self.total;@@total;end;end;F.new;puts F.total'
    result = minify_at_level(code, 4)
    assert_equal 'class F;@@a=0;def initialize =@@a+=1;def self.a =@@a;end;F.new;puts F.a', result.code
  end

  # === Dynamic cvar access exclusion ===

  def test_dynamic_cvar_access_prevents_rename
    code = 'class G;@@x=1;def self.x;class_variable_get(:@@x);end;end;puts G.x'
    result = minify_at_level(code, 4)
    assert_equal 'class G;@@x=1;def self.x =class_variable_get :@@x;end;puts G.x', result.code
  end

  # === Inherited cvar merge ===

  def test_inherited_cvars_use_same_short_name
    code = 'class A;@@shared=0;def self.shared;@@shared;end;end;class B<A;def inc;@@shared+=1;end;end;B.new.inc;puts A.shared'
    result = minify_at_level(code, 4)
    assert_equal 'class A;@@a=0;def self.a =@@a;end;class B<A;def a =@@a+=1;end;B.new.a;puts A.a', result.code
  end

# === Dynamic cvar access through a class object ===
#
# The receiver is the class whose variables the call reaches: a literal
# name keeps its spelling, a computed one excludes that class.

def test_literal_cvar_name_through_a_class_object_keeps_the_spelling
  code = 'class Counter;@@total_count=0;def self.bump;@@total_count+=1;end;end;' \
         'class Reporter;def self.read;Counter.class_variable_get(:@@total_count);end;end;Counter.bump;puts Reporter.read'
  result = minify_at_level(code, 4)
  assert_equal 'class A;@@total_count=0;def self.a =@@total_count+=1;end;' \
               'class B;def self.a =A.class_variable_get :@@total_count;end;A.a;puts B.a',
               result.code
end

def test_computed_cvar_name_through_a_class_object_excludes_that_class
  code = 'class Counter;@@total_count=0;def self.bump;@@total_count+=1;end;end;' \
         'class Reporter;def self.names;Counter.class_variables;end;end;Counter.bump;p Reporter.names'
  result = minify_at_level(code, 4)
  assert_equal 'class A;@@total_count=0;def self.a =@@total_count+=1;end;' \
               'class B;def self.a =A.class_variables;end;A.a;p B.a',
               result.code
end
end
