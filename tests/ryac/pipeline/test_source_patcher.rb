# frozen_string_literal: true

require_relative '../../test_helper'

class TestSourcePatcher < Minitest::Test
  # Create a test class that includes SourcePatcher to test its methods
  class Patcher
    include Ryac::Pipeline::SourcePatcher
    public :apply_patches, :mk, :src
  end

  def setup
    @patcher = Patcher.new
  end

  def test_apply_patches_empty
    assert_equal "hello", @patcher.apply_patches("hello", [])
  end

  def test_apply_patches_single
    patches = [{ start: 0, end: 5, replacement: "world" }]
    assert_equal "world", @patcher.apply_patches("hello", patches)
  end

  def test_apply_patches_multiple_non_overlapping
    patches = [
      { start: 0, end: 3, replacement: "X" },
      { start: 4, end: 7, replacement: "Y" }
    ]
    assert_equal "X Y", @patcher.apply_patches("foo bar", patches)
  end

  def test_apply_patches_preserves_encoding
    source = "hello"
    result = @patcher.apply_patches(source, [{ start: 0, end: 5, replacement: "world" }])
    assert_equal source.encoding, result.encoding
  end

  def test_mk_creates_patch_from_node
    source = "true"
    ast = Prism.parse(source).value.statements.body.first
    patch = @patcher.mk(ast, "!!1")
    assert_equal 0, patch[:start]
    assert_equal 4, patch[:end]
    assert_equal "!!1", patch[:replacement]
  end

  def test_src_extracts_source
    source = "foo + bar"
    ast = Prism.parse(source).value.statements.body.first
    # CallNode for "foo + bar" — receiver is "foo"
    assert_equal "foo", @patcher.src(source, ast.receiver)
  end

  def test_apply_patches_reverse_order
    # Patches should be applied from end to start so offsets stay valid
    patches = [
      { start: 0, end: 1, replacement: "XX" },
      { start: 4, end: 5, replacement: "YY" }
    ]
    assert_equal "XX234YY", @patcher.apply_patches("12345", patches)
  end

  def test_apply_patches_length_changing
    patches = [
      { start: 0, end: 5, replacement: "hi" },
      { start: 6, end: 11, replacement: "earth" }
    ]
    assert_equal "hi earth", @patcher.apply_patches("hello world", patches)
  end

  def test_apply_patches_unsorted_input
    # Patches given in forward order should still work (sorted internally)
    patches = [
      { start: 6, end: 11, replacement: "earth" },
      { start: 0, end: 5, replacement: "hi" }
    ]
    assert_equal "hi earth", @patcher.apply_patches("hello world", patches)
  end
end
