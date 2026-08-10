# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../test_helper'

class TestMethodRenameMapping < Minitest::Test
  include FakeNodeSupport

  def setup
    @mapping = RubyMinify::MethodRenameMapping.new
  end

  def test_add_method_and_assign_short_names
    key = [:MyClass, false, :my_method].freeze
    def_node = fake_node(100)
    @mapping.add_method(key, def_node)

    @mapping.assign_short_names({})

    assert_nil @mapping.short_name_for(loc_key(100))
  end

  def test_method_with_multiple_call_sites_gets_renamed
    key = [:MyClass, false, :my_long_method].freeze
    def_node = fake_node(100)
    @mapping.add_method(key, def_node)

    call_nodes = (1..5).map { |i| fake_node(200 + i) }
    call_nodes.each { |n| @mapping.add_call_site(n, key, has_receiver: true) }

    @mapping.assign_short_names({})

    short = @mapping.short_name_for(loc_key(100))
    assert_equal "a", short
    assert_equal "a", @mapping.short_name_for(loc_key(201))
    assert_equal "a", @mapping.short_name_for(loc_key(205))
  end

  def test_excluded_methods_not_renamed
    key = [:MyClass, false, :initialize].freeze
    def_node = fake_node(100)
    @mapping.add_method(key, def_node)

    5.times { |i| @mapping.add_call_site(fake_node(200 + i), key, has_receiver: true) }

    @mapping.assign_short_names({})

    assert_nil @mapping.short_name_for(loc_key(100))
  end

  def test_short_method_names_not_renamed
    key = [:MyClass, false, :x].freeze
    def_node = fake_node(100)
    @mapping.add_method(key, def_node)

    5.times { |i| @mapping.add_call_site(fake_node(200 + i), key, has_receiver: true) }

    @mapping.assign_short_names({})

    assert_nil @mapping.short_name_for(loc_key(100))
  end

  def test_two_char_method_names_not_renamed
    key = [:MyClass, false, :ab].freeze
    def_node = fake_node(100)
    @mapping.add_method(key, def_node)

    5.times { |i| @mapping.add_call_site(fake_node(200 + i), key, has_receiver: true) }

    @mapping.assign_short_names({})

    assert_nil @mapping.short_name_for(loc_key(100))
  end

  def test_merge_groups_assigns_same_name
    key1 = [:ClassA, false, :do_work].freeze
    key2 = [:ClassB, false, :do_work].freeze
    @mapping.add_method(key1, fake_node(100))
    @mapping.add_method(key2, fake_node(200))

    3.times { |i| @mapping.add_call_site(fake_node(300 + i), key1, has_receiver: true) }
    3.times { |i| @mapping.add_call_site(fake_node(400 + i), key2, has_receiver: true) }

    @mapping.merge_groups(key1, key2)
    @mapping.assign_short_names({})

    short1 = @mapping.short_name_for(loc_key(100))
    short2 = @mapping.short_name_for(loc_key(200))
    assert_equal "a", short1
    assert_equal "a", short2
  end

  def test_variable_collision_avoidance
    scope_id = [999, 999]
    mapping = RubyMinify::MethodRenameMapping.new
    key = [:MyClass, false, :my_method].freeze
    mapping.add_method(key, fake_node(100))

    # An implicit-receiver call site in a scope where a local already claimed
    # "a" — a bare `a` there would read the local, so the method must not
    # take that name.
    mapping.add_call_site(fake_node(201), key, has_receiver: false, scope_id: scope_id)

    4.times { |i| mapping.add_call_site(fake_node(202 + i), key, has_receiver: true) }

    scope_mappings = { scope_id => { my_var: 'a' } }
    mapping.assign_short_names(scope_mappings)

    assert_equal "b", mapping.short_name_for(loc_key(100))
  end

  def test_node_mapping_returns_dup
    key = [:MyClass, false, :my_method].freeze
    @mapping.add_method(key, fake_node(100))

    3.times { |i| @mapping.add_call_site(fake_node(200 + i), key, has_receiver: true) }
    @mapping.assign_short_names({})

    result = @mapping.node_mapping
    assert_equal 4, result.size
  end

  def test_cost_benefit_skips_unprofitable_rename
    key = [:MyClass, false, :abc].freeze
    @mapping.add_method(key, fake_node(100))
    @mapping.add_call_site(fake_node(200), key, has_receiver: true)

    @mapping.assign_short_names({})

    assert_equal "a", @mapping.short_name_for(loc_key(100))
  end

  # --- Tests for previously uncovered public methods ---

  def test_has_method
    key = [:MyClass, false, :my_method].freeze
    assert_equal false, @mapping.has_method?(key)

    @mapping.add_method(key, fake_node(100))
    assert_equal true, @mapping.has_method?(key)
  end

  def test_exclude_methods_by_mid
    key1 = [:ClassA, false, :do_work].freeze
    key2 = [:ClassB, false, :do_work].freeze
    key3 = [:ClassA, false, :other_method].freeze
    @mapping.add_method(key1, fake_node(100))
    @mapping.add_method(key2, fake_node(200))
    @mapping.add_method(key3, fake_node(300))

    @mapping.add_call_site(fake_node(400), key1, has_receiver: true)

    @mapping.exclude_methods_by_mid([:do_work].to_set)

    assert_equal false, @mapping.has_method?(key1)
    assert_equal false, @mapping.has_method?(key2)
    assert_equal true, @mapping.has_method?(key3)
  end

  def test_exclude_methods_by_mid_cleans_up_node_mappings
    key = [:MyClass, false, :do_work].freeze
    @mapping.add_method(key, fake_node(100))
    call = fake_node(200, cref_id: 999)
    @mapping.add_call_site(call, key, has_receiver: false)

    @mapping.exclude_methods_by_mid([:do_work].to_set)

    # After exclude, nodes should not appear in short name lookups even after assign
    @mapping.assign_short_names({})
    assert_nil @mapping.short_name_for(loc_key(100))
    assert_nil @mapping.short_name_for(loc_key(200))
  end

  def test_merge_all_by_mid
    key1 = [:ClassA, false, :do_work].freeze
    key2 = [:ClassB, false, :do_work].freeze
    key3 = [:ClassC, false, :do_work].freeze
    @mapping.add_method(key1, fake_node(100))
    @mapping.add_method(key2, fake_node(200))
    @mapping.add_method(key3, fake_node(300))

    3.times { |i| @mapping.add_call_site(fake_node(400 + i), key1, has_receiver: true) }
    3.times { |i| @mapping.add_call_site(fake_node(500 + i), key2, has_receiver: true) }
    3.times { |i| @mapping.add_call_site(fake_node(600 + i), key3, has_receiver: true) }

    @mapping.merge_all_by_mid(:do_work)
    @mapping.assign_short_names({})

    short1 = @mapping.short_name_for(loc_key(100))
    short2 = @mapping.short_name_for(loc_key(200))
    short3 = @mapping.short_name_for(loc_key(300))
    assert_equal "a", short1
    assert_equal "a", short2
    assert_equal "a", short3
  end

  def test_merge_all_by_mid_single_key_is_noop
    key = [:ClassA, false, :do_work].freeze
    @mapping.add_method(key, fake_node(100))
    3.times { |i| @mapping.add_call_site(fake_node(200 + i), key, has_receiver: true) }

    @mapping.merge_all_by_mid(:do_work)
    @mapping.assign_short_names({})

    assert_equal "a", @mapping.short_name_for(loc_key(100))
  end

  def test_add_unresolved_sites_for_mid
    key = [:MyClass, false, :my_method].freeze
    @mapping.add_method(key, fake_node(100))

    unresolved = (1..4).map { |i| fake_node(200 + i) }
    @mapping.add_unresolved_sites_for_mid(:my_method, unresolved)

    @mapping.assign_short_names({})

    short = @mapping.short_name_for(loc_key(100))
    assert_equal "a", short
    assert_equal "a", @mapping.short_name_for(loc_key(201))
    assert_equal "a", @mapping.short_name_for(loc_key(204))
  end

  def test_add_unresolved_sites_for_mid_unknown_method_is_noop
    unresolved = [fake_node(200)]
    @mapping.add_unresolved_sites_for_mid(:nonexistent, unresolved)

    assert_equal false, @mapping.has_method?([:anything, false, :nonexistent])
  end

  def test_short_name_for_key
    key = [:MyClass, false, :my_method].freeze
    @mapping.add_method(key, fake_node(100))
    3.times { |i| @mapping.add_call_site(fake_node(200 + i), key, has_receiver: true) }

    @mapping.assign_short_names({})

    short = @mapping.short_name_for_key(key)
    assert_equal "a", short
    assert_equal "a", @mapping.short_name_for(loc_key(100))
  end

  def test_short_name_for_key_returns_nil_when_not_renamed
    key = [:MyClass, false, :ab].freeze
    @mapping.add_method(key, fake_node(100))
    3.times { |i| @mapping.add_call_site(fake_node(200 + i), key, has_receiver: true) }

    @mapping.assign_short_names({})

    assert_nil @mapping.short_name_for_key(key)
  end

  def test_each_method_key
    key1 = [:ClassA, false, :method_a].freeze
    key2 = [:ClassB, false, :method_b].freeze
    @mapping.add_method(key1, fake_node(100))
    @mapping.add_method(key2, fake_node(200))

    keys = []
    @mapping.each_method_key { |k| keys << k }

    assert_equal 2, keys.size
    assert_equal true, keys.include?(key1)
    assert_equal true, keys.include?(key2)
  end

  def test_method_mids
    @mapping.add_method([:A, false, :foo].freeze, fake_node(100))
    @mapping.add_method([:B, false, :bar].freeze, fake_node(200))
    @mapping.add_method([:C, false, :foo].freeze, fake_node(300))

    mids = @mapping.method_mids
    assert_equal Set[:foo, :bar], mids
  end

  def test_each_cpath_for_mid
    @mapping.add_method([:ClassA, false, :work].freeze, fake_node(100))
    @mapping.add_method([:ClassB, true, :work].freeze, fake_node(200))
    @mapping.add_method([:ClassC, false, :other].freeze, fake_node(300))

    results = []
    @mapping.each_cpath_for_mid(:work) { |cpath, singleton| results << [cpath, singleton] }

    assert_equal 2, results.size
    assert_equal true, results.include?([:ClassA, false])
    assert_equal true, results.include?([:ClassB, true])
  end

  def test_add_method_with_nil_def_node
    key = [:MyClass, false, :my_method].freeze
    @mapping.add_method(key, nil)

    assert_equal true, @mapping.has_method?(key)
  end

  def test_no_call_sites_not_renamed
    key = [:MyClass, false, :my_long_method].freeze
    @mapping.add_method(key, fake_node(100))

    @mapping.assign_short_names({})

    assert_nil @mapping.short_name_for(loc_key(100))
  end

  # A def inference never saw called, while the same mid is called (and so
  # renamed) through another class: dispatch does not share the blind spot,
  # so the blind def must take the same short name.
  def test_merge_blind_def_groups_renames_blind_def_in_lockstep
    called = [:ClassA, false, :do_work].freeze
    blind = [:ClassB, false, :do_work].freeze
    @mapping.add_method(called, fake_node(100))
    @mapping.add_method(blind, fake_node(200))
    3.times { |i| @mapping.add_call_site(fake_node(300 + i), called, has_receiver: true) }

    @mapping.merge_blind_def_groups
    @mapping.assign_short_names({})

    assert_equal "a", @mapping.short_name_for(loc_key(100))
    assert_equal "a", @mapping.short_name_for(loc_key(200))
  end

  def test_merge_blind_def_groups_leaves_uncalled_mids_alone
    key1 = [:ClassA, false, :never_called].freeze
    key2 = [:ClassB, false, :never_called].freeze
    @mapping.add_method(key1, fake_node(100))
    @mapping.add_method(key2, fake_node(200))

    @mapping.merge_blind_def_groups
    @mapping.assign_short_names({})

    assert_nil @mapping.short_name_for(loc_key(100))
    assert_nil @mapping.short_name_for(loc_key(200))
  end

end
