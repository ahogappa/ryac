# frozen_string_literal: true

require_relative '../../../test_helper'

class TestIvarRenameMapping < Minitest::Test
  include FakeNodeSupport

  def setup
    @mapping = Ryac::SiteBucketMapping.new(prefix: '@')
  end

  # The merge records an alias: a site added for the child cpath afterwards
  # joins the merged bucket instead of silently resurrecting the child's.
  def test_site_added_after_merge_joins_the_merged_bucket
    @mapping.add_site([:Parent], :@some_counter, fake_node(1))
    @mapping.add_site([:Child], :@some_counter, fake_node(2))
    @mapping.merge_with_ancestor([:Child], [:Parent])
    @mapping.add_site([:Child], :@some_counter, fake_node(3))
    @mapping.assign_short_names
    assert_equal '@a', @mapping.node_mapping[loc_key(1)]
    assert_equal '@a', @mapping.node_mapping[loc_key(3)]
  end

  def test_site_added_after_freeze_is_rejected
    @mapping.assign_short_names
    error = assert_raises(Ryac::InternalError) do
      @mapping.add_site([:A], :@long_name, fake_node(1))
    end
    assert_equal '@-mapping: site added after assign_short_names', error.message
  end

  def test_short_ivar_not_renamed
    cpath = [:MyClass]
    @mapping.add_site(cpath, :@x, fake_node(1))
    @mapping.add_site(cpath, :@x, fake_node(2))
    @mapping.add_site(cpath, :@x, fake_node(3))
    @mapping.assign_short_names
    assert_nil @mapping.node_mapping[loc_key(1)]
  end

  def test_long_ivar_renamed
    cpath = [:MyClass]
    nodes = (1..5).map { |i| fake_node(i) }
    nodes.each { |n| @mapping.add_site(cpath, :@long_variable_name, n) }
    @mapping.assign_short_names
    short = @mapping.node_mapping[loc_key(1)]
    assert_equal "@a", short
    nodes.each { |n| assert_equal short, @mapping.node_mapping[loc_key(n.id)] }
  end

  # Sealing covers every mutator, not just add_site: a merge, exclusion or
  # reservation arriving after names are assigned is the same phase-order
  # bug and fails just as loudly.
  def test_mutation_after_seal_is_rejected
    @mapping.add_site([:A], :@long_name, fake_node(1))
    @mapping.assign_short_names
    error = assert_raises(Ryac::InternalError) { @mapping.merge_with_ancestor([:A], [:B]) }
    assert_equal '@-mapping: merge after assign_short_names', error.message
    error = assert_raises(Ryac::InternalError) { @mapping.exclude_cpath([:A]) }
    assert_equal '@-mapping: cpath excluded after assign_short_names', error.message
    error = assert_raises(Ryac::InternalError) { @mapping.reserve_name([:A], '@a') }
    assert_equal '@-mapping: name reserved after assign_short_names', error.message
  end

  def test_excluded_cpath_not_renamed
    cpath = [:MyClass]
    5.times { |i| @mapping.add_site(cpath, :@long_name, fake_node(i)) }
    @mapping.exclude_cpath(cpath)
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_reserved_name_skipped
    cpath = [:MyClass]
    5.times { |i| @mapping.add_site(cpath, :@long_name, fake_node(i)) }
    @mapping.reserve_name(cpath, "@a")
    @mapping.assign_short_names
    short = @mapping.node_mapping[loc_key(0)]
    assert_equal "@b", short
  end

  def test_merge_with_ancestor
    parent = [:Parent]
    child = [:Child]
    @mapping.add_site(parent, :@shared, fake_node(1))
    @mapping.add_site(child, :@shared, fake_node(2))
    @mapping.add_site(child, :@shared, fake_node(3))
    @mapping.merge_with_ancestor(child, parent)
    @mapping.assign_short_names
    short = @mapping.node_mapping[loc_key(1)]
    assert_equal short, @mapping.node_mapping[loc_key(2)]
    assert_equal short, @mapping.node_mapping[loc_key(3)]
  end

  def test_merge_moves_unique_child_ivars_to_ancestor
    parent = [:Parent]
    child = [:Child]
    @mapping.add_site(parent, :@parent_var, fake_node(1))
    @mapping.add_site(child, :@child_only, fake_node(2))
    3.times { |i| @mapping.add_site(child, :@child_only, fake_node(10 + i)) }
    @mapping.merge_with_ancestor(child, parent)
    @mapping.assign_short_names
    assert_equal "@a", @mapping.node_mapping[loc_key(2)]
  end

  def test_separate_cpaths_get_independent_names
    @mapping.add_site([:A], :@long_name, fake_node(1))
    @mapping.add_site([:A], :@long_name, fake_node(2))
    @mapping.add_site([:A], :@long_name, fake_node(3))
    @mapping.add_site([:B], :@long_name, fake_node(4))
    @mapping.add_site([:B], :@long_name, fake_node(5))
    @mapping.add_site([:B], :@long_name, fake_node(6))
    @mapping.assign_short_names
    assert_equal "@a", @mapping.node_mapping[loc_key(1)]
    assert_equal "@a", @mapping.node_mapping[loc_key(4)]
  end

  def test_sorted_by_savings_descending
    cpath = [:MyClass]
    # @very_long_variable_name (23 chars) x2 = savings 42
    2.times { |i| @mapping.add_site(cpath, :@very_long_variable_name, fake_node(100 + i)) }
    # @medium_name (12 chars) x5 = savings 50 — should get @a
    5.times { |i| @mapping.add_site(cpath, :@medium_name, fake_node(200 + i)) }
    @mapping.assign_short_names
    assert_equal "@a", @mapping.node_mapping[loc_key(200)]
    assert_equal "@b", @mapping.node_mapping[loc_key(100)]
  end

  def test_each_canonical_cpath
    @mapping.add_site([:A], :@long_name, fake_node(1))
    @mapping.add_site([:B], :@long_name, fake_node(2))
    cpaths = []
    @mapping.each_canonical_cpath { |c| cpaths << c }
    assert_equal [[:A], [:B]], cpaths.sort_by(&:to_s)
  end

  def test_merge_same_cpath_is_noop
    cpath = [:MyClass]
    @mapping.add_site(cpath, :@long_name, fake_node(1))
    @mapping.add_site(cpath, :@long_name, fake_node(2))
    @mapping.add_site(cpath, :@long_name, fake_node(3))
    @mapping.merge_with_ancestor(cpath, cpath)
    @mapping.assign_short_names
    assert_equal "@a", @mapping.node_mapping[loc_key(1)]
  end

  def test_merge_with_unregistered_ancestor_is_noop
    child = [:Child]
    parent = [:Parent]
    @mapping.add_site(child, :@long_name, fake_node(1))
    @mapping.add_site(child, :@long_name, fake_node(2))
    @mapping.add_site(child, :@long_name, fake_node(3))
    @mapping.merge_with_ancestor(child, parent)
    @mapping.assign_short_names
    assert_equal "@a", @mapping.node_mapping[loc_key(1)]
  end

  def test_merge_with_unregistered_child_is_noop
    parent = [:Parent]
    child = [:Child]
    @mapping.add_site(parent, :@long_name, fake_node(1))
    @mapping.add_site(parent, :@long_name, fake_node(2))
    @mapping.add_site(parent, :@long_name, fake_node(3))
    @mapping.merge_with_ancestor(child, parent)
    @mapping.assign_short_names
    assert_equal "@a", @mapping.node_mapping[loc_key(1)]
  end

end
