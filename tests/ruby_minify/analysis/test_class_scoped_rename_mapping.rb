# frozen_string_literal: true

require_relative '../../test_helper'

# Unit tests for the behavior shared by IvarRenameMapping and CvarRenameMapping
# through their common ClassScopedRenameMapping base. The concrete sigil/length
# behavior is covered by the per-kind tests; here we exercise the base contract:
# the abstract hooks subclasses must implement and the canonical-cpath
# resolution (including cycle protection).
class TestClassScopedRenameMapping < Minitest::Test
  include FakeNodeSupport

  # Minimal concrete subclass that records which cpath each site landed under,
  # so tests can assert how canonical resolution rewrites the key.
  class Recorder < RubyMinify::ClassScopedRenameMapping
    def canonical_for(cpath)
      send(:resolve_canonical, cpath)
    end

    def alias_cpath(from, to)
      @cpath_to_canonical[from] = to
    end

    private

    def name_prefix = "@"
    def keep_threshold = 2
  end

  def test_name_prefix_is_abstract_in_base
    base = RubyMinify::ClassScopedRenameMapping.new
    error = assert_raises(NotImplementedError) { base.send(:name_prefix) }
    assert_includes error.message, 'name_prefix'
  end

  def test_keep_threshold_is_abstract_in_base
    base = RubyMinify::ClassScopedRenameMapping.new
    error = assert_raises(NotImplementedError) { base.send(:keep_threshold) }
    assert_includes error.message, 'keep_threshold'
  end

  def test_assign_short_names_in_base_raises_without_hooks
    base = RubyMinify::ClassScopedRenameMapping.new
    base.add_read_site([:Foo], :@long_variable, fake_node(0))
    assert_raises(NotImplementedError) { base.assign_short_names }
  end

  def test_canonical_resolution_follows_alias_chain
    rec = Recorder.new
    rec.alias_cpath([:A], [:B])
    rec.alias_cpath([:B], [:C])
    assert_equal [:C], rec.canonical_for([:A])
  end

  def test_canonical_resolution_is_cycle_safe
    rec = Recorder.new
    rec.alias_cpath([:A], [:B])
    rec.alias_cpath([:B], [:A])
    # Must terminate rather than loop forever; result is one end of the cycle.
    result = rec.canonical_for([:A])
    assert_includes [[:A], [:B]], result
  end

  def test_sites_are_recorded_under_canonical_cpath
    rec = Recorder.new
    rec.alias_cpath([:Child], [:Parent])
    rec.add_read_site([:Child], :@value, fake_node(0))
    canonicals = []
    rec.each_canonical_cpath { |c| canonicals << c }
    assert_equal [[:Parent]], canonicals
  end

  def test_reserve_name_blocks_that_short_name
    rec = Recorder.new
    # Reserve "@a" so the long ivar is forced to the next generated name.
    rec.reserve_name([:Foo], "@a")
    5.times { |i| rec.add_read_site([:Foo], :@longvar, fake_node(i)) }
    rec.assign_short_names
    refute_equal "@a", rec.node_mapping[loc_key(0)]
    refute_nil rec.node_mapping[loc_key(0)]
  end
end
