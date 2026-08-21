# frozen_string_literal: true

require_relative '../../test_helper'

# The coordinate seam between TypeProf's tree and Prism's lives inside the
# oracle: tp_key converts a TypeProf node to the location key of the Prism
# node it was built from, and AstUtils keys Prism nodes only.
class TestTypeOracle < Minitest::Test
  def oracle
    Ryac::TypeOracle.new(nil, nil)
  end

  def test_tp_key_reads_through_to_the_prism_node
    prism_node = Prism.parse('bar').value.statements.body.first
    wrapper = Object.new
    wrapper.instance_variable_set(:@raw_node, prism_node)
    assert_equal [0, 3], oracle.send(:tp_key, wrapper)
  end

  # A node nothing can point back at cannot be renamed, so this refuses
  # rather than inventing a key that would silently never match a patch
  # site.
  def test_tp_key_rejects_a_node_with_no_source_location
    error = assert_raises(ArgumentError) { oracle.send(:tp_key, Object.new) }
    assert_equal 'no source location behind Object', error.message
  end
end
