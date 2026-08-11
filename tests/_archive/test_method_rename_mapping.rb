# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/ryac'

class TestMethodRenameMapping < Minitest::Test
  def setup
    @mapping = Ryac::MethodRenameMapping.new
  end

  def test_add_method_and_freeze_mapping
    key = [:MyClass, false, :my_method].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)

    @mapping.freeze_mapping({})

    # Single definition site only (count=1), not enough savings to rename
    assert_nil @mapping.short_name_for([100 << 20, 100 << 20])
  end

  def test_method_with_multiple_call_sites_gets_renamed
    key = [:MyClass, false, :my_long_method].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)

    # Add enough call sites to make renaming worthwhile
    call_nodes = (1..5).map { |i| FakeNode.new(200 + i) }
    call_nodes.each { |n| @mapping.add_call_site(n, key, has_receiver: true) }

    @mapping.freeze_mapping({})

    # Method has 6 occurrences (1 def + 5 calls), original name "my_long_method" = 14 chars
    # Short name "a" = 1 char, savings = (14 - 1) * 6 = 78 chars, worth it
    short = @mapping.short_name_for([100 << 20, 100 << 20])
    refute_nil short, "Method with enough usage should be renamed"
    assert_equal short, @mapping.short_name_for([201 << 20, 201 << 20]), "Call sites should get same short name"
    assert_equal short, @mapping.short_name_for([205 << 20, 205 << 20]), "All call sites should get same short name"
  end

  def test_excluded_methods_not_renamed
    key = [:MyClass, false, :initialize].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)

    5.times { |i| @mapping.add_call_site(FakeNode.new(200 + i), key, has_receiver: true) }

    @mapping.freeze_mapping({})

    assert_nil @mapping.short_name_for([100 << 20, 100 << 20]), "initialize should not be renamed"
  end

  def test_short_method_names_not_renamed
    # Method name "x" is 1 char (<= 2), should not be renamed
    key = [:MyClass, false, :x].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)

    5.times { |i| @mapping.add_call_site(FakeNode.new(200 + i), key, has_receiver: true) }

    @mapping.freeze_mapping({})

    assert_nil @mapping.short_name_for([100 << 20, 100 << 20]), "Single-char method name should not be renamed"
  end

  def test_two_char_method_names_not_renamed
    # Method name "ab" is 2 chars (<= 2), should not be renamed for idempotency
    key = [:MyClass, false, :ab].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)

    5.times { |i| @mapping.add_call_site(FakeNode.new(200 + i), key, has_receiver: true) }

    @mapping.freeze_mapping({})

    assert_nil @mapping.short_name_for([100 << 20, 100 << 20]), "Two-char method name should not be renamed"
  end

  def test_merge_groups_assigns_same_name
    key1 = [:ClassA, false, :do_work].freeze
    key2 = [:ClassB, false, :do_work].freeze
    def_node1 = FakeNode.new(100)
    def_node2 = FakeNode.new(200)
    @mapping.add_method(key1, def_node1)
    @mapping.add_method(key2, def_node2)

    3.times { |i| @mapping.add_call_site(FakeNode.new(300 + i), key1, has_receiver: true) }
    3.times { |i| @mapping.add_call_site(FakeNode.new(400 + i), key2, has_receiver: true) }

    @mapping.merge_groups(key1, key2)

    @mapping.freeze_mapping({})

    short1 = @mapping.short_name_for([100 << 20, 100 << 20])
    short2 = @mapping.short_name_for([200 << 20, 200 << 20])
    refute_nil short1
    refute_nil short2
    assert_equal short1, short2, "Merged groups should get the same short name"
  end

  def test_variable_collision_avoidance
    key = [:MyClass, false, :my_method].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)

    # Call site without receiver in a scope that already uses 'a' as a variable
    call_node = FakeNode.new(201, cref_id: 999)
    @mapping.add_call_site(call_node, key, has_receiver: false)

    4.times { |i| @mapping.add_call_site(FakeNode.new(202 + i), key, has_receiver: true) }

    # scope_mappings has variable 'a' in the same scope as call_node's cref
    cref_object_id = call_node.lenv.cref.object_id
    scope_mappings = { cref_object_id => { my_var: 'a' } }
    @mapping.freeze_mapping(scope_mappings)

    short = @mapping.short_name_for([100 << 20, 100 << 20])
    refute_nil short
    refute_equal 'a', short, "Should skip 'a' due to variable collision"
  end

  def test_node_mapping_returns_hash
    key = [:MyClass, false, :my_method].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)

    3.times { |i| @mapping.add_call_site(FakeNode.new(200 + i), key, has_receiver: true) }

    @mapping.freeze_mapping({})

    result = @mapping.node_mapping
    assert_instance_of Hash, result
  end

  def test_cost_benefit_skips_unprofitable_rename
    # Method name "abc" (3 chars), with just 2 occurrences (1 def + 1 call)
    # Short name "a" (1 char), savings = (3 - 1) * 2 = 4 chars > 2 threshold
    # But we also test that very marginal savings are still applied if above threshold
    key = [:MyClass, false, :abc].freeze
    def_node = FakeNode.new(100)
    @mapping.add_method(key, def_node)
    @mapping.add_call_site(FakeNode.new(200), key, has_receiver: true)

    @mapping.freeze_mapping({})

    # savings = (3-1) * 2 = 4 > 2, so this should be renamed
    refute_nil @mapping.short_name_for([100 << 20, 100 << 20]), "Method with sufficient savings should be renamed"
  end

  private

  # Fake node for testing (simulates code_range for location_key and optional lenv.cref)
  FakeNode = Struct.new(:id, :cref_id, keyword_init: true) do
    def initialize(id, cref_id: nil)
      super(id: id, cref_id: cref_id)
    end

    def code_range
      FakeCodeRange.new(id)
    end

    def lenv
      return nil unless cref_id
      FakeLenv.new(cref_id)
    end
  end

  FakeCodeRange = Struct.new(:id) do
    def first
      FakePosition.new(id, 0)
    end

    def last
      FakePosition.new(id, 0)
    end
  end

  FakePosition = Struct.new(:lineno, :column)

  FAKE_CREF_CACHE = {}

  FakeLenv = Struct.new(:cref_id) do
    def cref
      FAKE_CREF_CACHE[cref_id] ||= FakeCref.new
    end
  end

  FakeCref = Struct.new(keyword_init: true) do
    def outer
      nil
    end
  end
end
