# frozen_string_literal: true

require_relative '../../../test_helper'

class TestCvarRenameMapping < Minitest::Test
  include FakeNodeSupport

  def setup
    @mapping = Ryac::SiteBucketMapping.new(prefix: '@@')
  end

  # "@@" plus one character is already minimal — the kept-name threshold
  # derives from the prefix.
  def test_short_cvar_not_renamed
    cpath = [:MyClass]
    5.times { |i| @mapping.add_site(cpath, :@@a, fake_node(i)) }
    @mapping.assign_short_names
    assert_nil @mapping.node_mapping[loc_key(0)]
  end

  def test_four_char_cvar_renamed
    cpath = [:MyClass]
    5.times { |i| @mapping.add_site(cpath, :@@ab, fake_node(i)) }
    @mapping.assign_short_names
    assert_equal "@@a", @mapping.node_mapping[loc_key(0)]
  end

  def test_long_cvar_renamed_with_double_at_prefix
    cpath = [:MyClass]
    5.times { |i| @mapping.add_site(cpath, :@@long_class_var, fake_node(i)) }
    @mapping.assign_short_names
    assert_equal "@@a", @mapping.node_mapping[loc_key(0)]
  end

  def test_excluded_cpath_not_renamed
    cpath = [:MyClass]
    5.times { |i| @mapping.add_site(cpath, :@@long_name, fake_node(i)) }
    @mapping.exclude_cpath(cpath)
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_merge_with_ancestor
    parent = [:Parent]
    child = [:Child]
    @mapping.add_site(parent, :@@shared, fake_node(1))
    @mapping.add_site(child, :@@shared, fake_node(2))
    @mapping.add_site(child, :@@shared, fake_node(3))
    @mapping.merge_with_ancestor(child, parent)
    @mapping.assign_short_names
    short = @mapping.node_mapping[loc_key(1)]
    assert_equal short, @mapping.node_mapping[loc_key(2)]
    assert_equal short, @mapping.node_mapping[loc_key(3)]
  end

  def test_each_canonical_cpath
    @mapping.add_site([:A], :@@x, fake_node(1))
    @mapping.add_site([:B], :@@y, fake_node(2))
    cpaths = []
    @mapping.each_canonical_cpath { |c| cpaths << c }
    assert_equal [[:A], [:B]], cpaths.sort
  end

  def test_merge_child_unique_cvar_moved_to_ancestor
    parent = [:Parent]
    child = [:Child]
    @mapping.add_site(parent, :@@parent_var, fake_node(1))
    @mapping.add_site(child, :@@child_only_var, fake_node(2))
    @mapping.merge_with_ancestor(child, parent)
    cpaths = []
    @mapping.each_canonical_cpath { |c| cpaths << c }
    assert_equal [[:Parent]], cpaths
    @mapping.assign_short_names
    assert_equal "@@b", @mapping.node_mapping[loc_key(1)]
    assert_equal "@@a", @mapping.node_mapping[loc_key(2)]
  end

  def test_merge_noop_when_same_canonical
    cpath = [:Same]
    @mapping.add_site(cpath, :@@long_name, fake_node(1))
    @mapping.merge_with_ancestor(cpath, cpath)
    @mapping.assign_short_names
    assert_equal "@@a", @mapping.node_mapping[loc_key(1)]
  end

  def test_merge_noop_when_ancestor_not_present
    @mapping.add_site([:Child], :@@long_name, fake_node(1))
    @mapping.merge_with_ancestor([:Child], [:Unknown])
    @mapping.assign_short_names
    assert_equal "@@a", @mapping.node_mapping[loc_key(1)]
  end

  def test_merge_noop_when_child_not_present
    @mapping.add_site([:Parent], :@@long_name, fake_node(1))
    @mapping.merge_with_ancestor([:Ghost], [:Parent])
    @mapping.assign_short_names
    assert_equal "@@a", @mapping.node_mapping[loc_key(1)]
  end

  def test_assign_skips_existing_short_name_collision
    cpath = [:MyClass]
    @mapping.add_site(cpath, :@@a, fake_node(1))
    5.times { |i| @mapping.add_site(cpath, :@@long_name, fake_node(10 + i)) }
    @mapping.assign_short_names
    assert_equal "@@b", @mapping.node_mapping[loc_key(10)]
  end
end
