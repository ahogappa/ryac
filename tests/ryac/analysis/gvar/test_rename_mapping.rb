# frozen_string_literal: true

require_relative '../../../test_helper'

class TestGvarRenameMapping < Minitest::Test
  include FakeNodeSupport

  def setup
    @mapping = Ryac::GvarRenameMapping.new
  end

  def test_builtin_global_ignored
    @mapping.add_site(:$stdout, fake_node(1))
    @mapping.add_site(:$stderr, fake_node(2))
    @mapping.add_site(:"$:", fake_node(3))
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_numbered_global_ignored
    @mapping.add_site(:$1, fake_node(1))
    @mapping.add_site(:$9, fake_node(2))
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_short_gvar_not_renamed
    3.times { |i| @mapping.add_site(:$x, fake_node(i)) }
    @mapping.assign_short_names
    assert_nil @mapping.node_mapping[loc_key(0)]
  end

  def test_long_gvar_renamed
    @mapping.add_site(:$my_global_var, fake_node(0), write: true)
    4.times { |i| @mapping.add_site(:$my_global_var, fake_node(i + 1)) }
    @mapping.assign_short_names
    short = @mapping.node_mapping[loc_key(0)]
    assert_equal "$a", short
  end

  # A global the program never writes is either a built-in this mapping does
  # not know or nil everywhere — renaming it can only break the program.
  def test_read_only_gvar_not_renamed
    5.times { |i| @mapping.add_site(:$some_engine_flag, fake_node(i)) }
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_english_builtin_globals_ignored
    @mapping.add_site(:$LOAD_PATH, fake_node(1), write: true)
    @mapping.add_site(:$PROGRAM_NAME, fake_node(2), write: true)
    @mapping.add_site(:$LOADED_FEATURES, fake_node(3), write: true)
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_gvar_prefix_is_dollar
    @mapping.add_site(:$long_name, fake_node(0), write: true)
    2.times { |i| @mapping.add_site(:$long_name, fake_node(i + 1)) }
    @mapping.assign_short_names
    short = @mapping.node_mapping[loc_key(0)]
    assert short.start_with?("$")
  end

  def test_excluded_name_not_renamed
    5.times { |i| @mapping.add_site(:$my_global, fake_node(i)) }
    @mapping.exclude_name(:$my_global)
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_multiple_gvars_sorted_by_savings
    # $very_long_global_name (22 chars) x2 = savings 40
    2.times { |i| @mapping.add_site(:$very_long_global_name, fake_node(100 + i), write: true) }
    # $medium_name (12 chars) x5 = savings 50 — should get $a
    5.times { |i| @mapping.add_site(:$medium_name, fake_node(200 + i), write: true) }
    @mapping.assign_short_names
    assert_equal "$a", @mapping.node_mapping[loc_key(200)]
    assert_equal "$b", @mapping.node_mapping[loc_key(100)]
  end

  def test_skips_existing_short_name
    # $a is a short (<=2 char) gvar, so it occupies the name "$a"
    @mapping.add_site(:$a, fake_node(0))
    5.times { |i| @mapping.add_site(:$long_global_var, fake_node(10 + i), write: true) }
    @mapping.assign_short_names
    # $a is taken by existing short gvar, so $long_global_var gets $b
    assert_equal "$b", @mapping.node_mapping[loc_key(10)]
  end
end
