# frozen_string_literal: true

require_relative '../../../test_helper'

class TestCvarCollection < Minitest::Test
  include MinifyTestHelper

  # === Basic cvar collection and renaming ===

  def test_cvar_renamed
    code = 'class F;@@total=0;def initialize;@@total+=1;end;def self.total;@@total;end;end;F.new;puts F.total'
    result = minify_at_level(code, 4)
    assert_equal 'class F;@@a=0;def initialize =@@a+=1;def self.total =@@a;end;F.new;puts F.total', result.code
  end

  # === Dynamic cvar access exclusion ===

  def test_dynamic_cvar_access_prevents_rename
    code = 'class G;@@x=1;def self.x;class_variable_get(:@@x);end;end;puts G.x'
    result = minify_at_level(code, 4)
    assert_equal 'class G;@@x=1;def self.x =class_variable_get :"@@x";end;puts G.x', result.code
  end

  # === Inherited cvar merge ===

  def test_inherited_cvars_use_same_short_name
    code = 'class A;@@shared=0;def self.shared;@@shared;end;end;class B<A;def inc;@@shared+=1;end;end;B.new.inc;puts A.shared'
    result = minify_at_level(code, 4)
    assert_equal 'class A;@@a=0;def self.shared =@@a;end;class B<A;def inc =@@a+=1;end;B.new.inc;puts A.shared', result.code
  end
end
