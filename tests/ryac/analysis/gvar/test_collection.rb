# frozen_string_literal: true

require_relative '../../../test_helper'

class TestGvarCollection < Minitest::Test
  include MinifyTestHelper

  # === Basic gvar collection and renaming ===

  def test_gvar_renamed
    code = '$my_counter=0;$my_counter+=1;puts $my_counter'
    result = minify_at_level(code, 4)
    assert_equal '$a=0;$a+=1;puts $a', result.code
  end

  # === Alias exclusion ===

  def test_aliased_gvar_not_renamed
    code = '$my_var=1;alias $my_alias $my_var;puts $my_alias'
    result = minify_at_level(code, 4)
    assert_equal '$my_var=1;alias $my_alias $my_var;puts $my_alias', result.code
  end
end
