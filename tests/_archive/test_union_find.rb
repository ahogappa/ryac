# frozen_string_literal: true

require_relative 'test_helper'

# Test wrapper that includes UnionFind and exposes its methods
class UnionFindWrapper
  include Ryac::UnionFind

  def initialize
    uf_init
  end

  def add(key)
    uf_add(key)
  end

  def root(key)
    uf_root(key)
  end

  def merge(key1, key2)
    merge_groups(key1, key2)
  end

  def remove(key)
    uf_remove(key)
  end
end

class TestUnionFind < Minitest::Test
  def setup
    @uf = UnionFindWrapper.new
  end

  def test_single_element_is_its_own_root
    @uf.add(:a)
    assert_equal :a, @uf.root(:a)
  end

  def test_merge_two_elements_share_root
    @uf.add(:a)
    @uf.add(:b)
    @uf.merge(:a, :b)
    assert_equal @uf.root(:a), @uf.root(:b)
  end

  def test_unmerged_elements_have_different_roots
    @uf.add(:a)
    @uf.add(:b)
    refute_equal @uf.root(:a), @uf.root(:b)
  end

  def test_merge_is_transitive
    @uf.add(:a)
    @uf.add(:b)
    @uf.add(:c)
    @uf.merge(:a, :b)
    @uf.merge(:b, :c)
    assert_equal @uf.root(:a), @uf.root(:c)
  end

  def test_merge_idempotent
    @uf.add(:a)
    @uf.add(:b)
    @uf.merge(:a, :b)
    root_before = @uf.root(:a)
    @uf.merge(:a, :b)
    assert_equal root_before, @uf.root(:a)
  end

  def test_multiple_independent_groups
    @uf.add(:a)
    @uf.add(:b)
    @uf.add(:c)
    @uf.add(:d)
    @uf.merge(:a, :b)
    @uf.merge(:c, :d)
    assert_equal @uf.root(:a), @uf.root(:b)
    assert_equal @uf.root(:c), @uf.root(:d)
    refute_equal @uf.root(:a), @uf.root(:c)
  end

  def test_merge_groups_connects_independent_groups
    @uf.add(:a)
    @uf.add(:b)
    @uf.add(:c)
    @uf.add(:d)
    @uf.merge(:a, :b)
    @uf.merge(:c, :d)
    @uf.merge(:b, :c)
    assert_equal @uf.root(:a), @uf.root(:d)
  end

  def test_path_compression
    @uf.add(:a)
    @uf.add(:b)
    @uf.add(:c)
    @uf.merge(:a, :b)
    @uf.merge(:b, :c)
    # After finding root of :c, path should be compressed
    root = @uf.root(:c)
    assert_equal root, @uf.root(:c)
    assert_equal root, @uf.root(:b)
    assert_equal root, @uf.root(:a)
  end

  def test_remove_element
    @uf.add(:a)
    @uf.add(:b)
    @uf.merge(:a, :b)
    @uf.remove(:b)
    # :a should still have a root
    assert_equal :a, @uf.root(:a)
  end

  def test_works_with_integer_keys
    @uf.add(1)
    @uf.add(2)
    @uf.add(3)
    @uf.merge(1, 2)
    assert_equal @uf.root(1), @uf.root(2)
    refute_equal @uf.root(1), @uf.root(3)
  end

  def test_works_with_array_keys
    @uf.add([:Foo])
    @uf.add([:Bar])
    @uf.merge([:Foo], [:Bar])
    assert_equal @uf.root([:Foo]), @uf.root([:Bar])
  end

  def test_many_elements_union
    100.times { |i| @uf.add(i) }
    99.times { |i| @uf.merge(i, i + 1) }
    root = @uf.root(0)
    100.times { |i| assert_equal root, @uf.root(i) }
  end
end
