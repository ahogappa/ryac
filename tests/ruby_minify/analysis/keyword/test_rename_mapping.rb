# frozen_string_literal: true

require_relative '../../../test_helper'

class TestKeywordRenameMapping < Minitest::Test
  include FakeNodeSupport

  # Fake node that satisfies is_a?(TypeProf::Core::AST::LocalVariableReadNode)
  # for testing build_variable_hints
  class FakeLocalVarNode < TypeProf::Core::AST::LocalVariableReadNode
    attr_reader :var

    def initialize(id, var:, cref_id:)
      @id = id
      @var = var
      @cref_id = cref_id
    end

    def code_range = FakeNodeSupport::FakeCodeRange.new(@id)

    def lenv
      return nil unless @cref_id
      FakeNodeSupport::FakeLenv.new(@cref_id)
    end
  end

  def setup
    @mapping = RubyMinify::KeywordRenameMapping.new
  end

  def test_no_call_sites_no_rename
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_keyword_renamed_with_call_sites
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    3.times do |i|
      @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), fake_node(200 + i))
    end
    @mapping.assign_short_names
    short = @mapping.node_mapping[loc_key(100)]
    assert_equal "a", short
    assert_equal short, @mapping.node_mapping[loc_key(101)]
    assert_equal short, @mapping.node_mapping[loc_key(102)]
  end

  def test_short_keyword_not_renamed
    key = [:MyClass, false, :foo]
    @mapping.add_keyword_def(key, :ab)
    3.times { |i| @mapping.add_keyword_call(key, :ab, fake_node(100 + i), fake_node(200 + i)) }
    @mapping.assign_short_names
    assert_nil @mapping.node_mapping[loc_key(100)]
  end

  def test_excluded_method_not_renamed
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), fake_node(200 + i)) }
    @mapping.exclude_method(key)
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_exclude_propagates_to_merged_group
    key1 = [:ClassA, false, :do_work]
    key2 = [:ClassB, false, :do_work]
    @mapping.add_keyword_def(key1, :long_keyword)
    @mapping.add_keyword_def(key2, :long_keyword)
    3.times { |i| @mapping.add_keyword_call(key1, :long_keyword, fake_node(100 + i), fake_node(200 + i)) }
    3.times { |i| @mapping.add_keyword_call(key2, :long_keyword, fake_node(300 + i), fake_node(400 + i)) }
    @mapping.merge_groups(key1, key2)
    @mapping.exclude_method(key1)
    @mapping.assign_short_names
    assert_empty @mapping.node_mapping
  end

  def test_merged_groups_share_keyword_names
    key1 = [:ClassA, false, :process]
    key2 = [:ClassB, false, :process]
    @mapping.add_keyword_def(key1, :long_keyword)
    @mapping.add_keyword_def(key2, :long_keyword)
    3.times { |i| @mapping.add_keyword_call(key1, :long_keyword, fake_node(100 + i), fake_node(200 + i)) }
    3.times { |i| @mapping.add_keyword_call(key2, :long_keyword, fake_node(300 + i), fake_node(400 + i)) }
    @mapping.merge_groups(key1, key2)
    @mapping.assign_short_names
    short1 = @mapping.node_mapping[loc_key(100)]
    short2 = @mapping.node_mapping[loc_key(300)]
    assert_equal "a", short1
    assert_equal "a", short2
  end

  def test_savings_threshold
    key = [:MyClass, false, :foo]
    # keyword "abc" (3 chars), short "a" (1 char)
    # 1 def + 1 call = 2 occurrences, savings = (3-1)*2 = 4 > 2 → rename
    @mapping.add_keyword_def(key, :abc)
    @mapping.add_keyword_call(key, :abc, fake_node(100), fake_node(200))
    @mapping.assign_short_names
    assert_equal "a", @mapping.node_mapping[loc_key(100)]
  end

  def test_def_node_mapping
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), fake_node(200 + i)) }
    @mapping.assign_short_names

    def_node = fake_node(1)
    registry = { key => [def_node] }
    result = @mapping.def_node_mapping(registry)
    assert_equal({ long_keyword: "a" }, result[loc_key(1)])
  end

  def test_def_node_mapping_skips_excluded_method
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), fake_node(200 + i)) }
    @mapping.assign_short_names

    @mapping.exclude_method(key)

    def_node = fake_node(1)
    registry = { key => [def_node] }
    result = @mapping.def_node_mapping(registry)
    assert_equal({}, result)
  end

  def test_def_node_mapping_skips_unknown_method
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), fake_node(200 + i)) }
    @mapping.assign_short_names

    unknown_key = [:Other, false, :other]
    def_node = fake_node(1)
    registry = { unknown_key => [def_node] }
    result = @mapping.def_node_mapping(registry)
    assert_equal({}, result)
  end

  def test_each_method_key
    key1 = [:ClassA, false, :foo]
    key2 = [:ClassB, false, :bar]
    @mapping.add_keyword_def(key1, :long_keyword)
    @mapping.add_keyword_def(key2, :long_keyword)

    keys = []
    @mapping.each_method_key { |k| keys << k }
    assert_equal [key1, key2].sort_by(&:to_s), keys.sort_by(&:to_s)
  end

  def test_build_variable_hints_with_renamed_keyword
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    val_node = FakeLocalVarNode.new(200, var: :my_var, cref_id: 1)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), val_node) }
    @mapping.assign_short_names

    hints = @mapping.build_variable_hints { |n| n.lenv&.cref&.object_id }
    cref_oid = val_node.lenv.cref.object_id
    assert_equal "a", hints[cref_oid][:my_var]
  end

  def test_build_variable_hints_short_keyword_uses_original_name
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :ab)
    val_node = FakeLocalVarNode.new(200, var: :x, cref_id: 1)
    3.times { |i| @mapping.add_keyword_call(key, :ab, fake_node(100 + i), val_node) }
    @mapping.assign_short_names

    hints = @mapping.build_variable_hints { |n| n.lenv&.cref&.object_id }
    cref_oid = val_node.lenv.cref.object_id
    assert_equal "ab", hints[cref_oid][:x]
  end

  def test_build_variable_hints_skips_non_local_var_nodes
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), fake_node(200 + i)) }
    @mapping.assign_short_names

    hints = @mapping.build_variable_hints { |n| n.lenv&.cref&.object_id }
    assert_equal({}, hints)
  end

  def test_build_variable_hints_skips_excluded_method
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    val_node = FakeLocalVarNode.new(200, var: :my_var, cref_id: 1)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), val_node) }
    @mapping.exclude_method(key)
    @mapping.assign_short_names

    hints = @mapping.build_variable_hints { |n| n.lenv&.cref&.object_id }
    assert_equal({}, hints)
  end

  def test_build_variable_hints_skips_node_without_cref
    key = [:MyClass, false, :my_method]
    @mapping.add_keyword_def(key, :long_keyword)
    val_node = FakeLocalVarNode.new(200, var: :my_var, cref_id: nil)
    3.times { |i| @mapping.add_keyword_call(key, :long_keyword, fake_node(100 + i), val_node) }
    @mapping.assign_short_names

    hints = @mapping.build_variable_hints { |n| n.lenv&.cref&.object_id }
    assert_equal({}, hints)
  end
end
