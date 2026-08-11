# frozen_string_literal: true

require_relative '../../test_helper'

class TestPreprocessor < Minitest::Test
  def setup
    @preprocessor = Ryac::Pipeline::Preprocessor.new
  end

  def preprocess(code)
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: code,
      file_boundaries: [],
      original_size: code.bytesize,
      stdlib_requires: [],
      rbs_files: {}
    )
    @preprocessor.call(source).content
  end

  def test_block_forwarding_does_not_produce_invalid_syntax
    # Naming/BlockForwarding rewrites &block → &
    # Style/ArgumentsForwarding must NOT also fire, or the combined
    # correction produces invalid code like `template((name, &))`
    code = <<~RUBY
      def layout(name = :layout, &block)
        template name, &block
      end
    RUBY
    result = preprocess(code)
    # Must be valid Ruby
    assert Prism.parse(result).success?, "Preprocessed code has syntax errors:\n#{result}"
    # Naming/BlockForwarding should rewrite &block → &
    assert_equal "def layout(name = :layout, &)\n  template(name, &)\nend\n", result
  end

  def test_redundant_return_removed
    assert_equal "def foo\n  1\nend\n", preprocess("def foo\n  return 1\nend\n")
  end

  def test_symbol_proc
    assert_equal "[1].map(&:to_s)\n", preprocess("[1].map { |x| x.to_s }\n")
  end

  def test_metadata_passthrough
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: "x = 1\n",
      file_boundaries: [{ file: 'a.rb', start: 0, end: 5 }],
      original_size: 42,
      stdlib_requires: ['json'],
      rbs_files: { 'a.rbs' => 'class A end' }
    )
    result = @preprocessor.call(source)
    assert_equal [{ file: 'a.rb', start: 0, end: 5 }], result.file_boundaries
    assert_equal 42, result.original_size
    assert_equal ['json'], result.stdlib_requires
    assert_equal({ 'a.rbs' => 'class A end' }, result.rbs_files)
  end

  def test_special_global_vars_uses_perl_names
    assert_equal "puts $0\n", preprocess("puts $PROGRAM_NAME\n")
  end

  def test_lambda_literal_style
    assert_equal "f = ->(x) { x + 1 }\n", preprocess("f = lambda { |x| x + 1 }\n")
  end

  def test_sole_nested_conditional
    # SoleNestedConditional merges nested ifs, but IfUnlessModifier is not
    # applied here — ControlFlowSimplify handles modifier form post-compaction.
    assert_equal "if a && b\n    c\n  end\n", preprocess("if a\n  if b\n    c\n  end\nend\n")
  end

  def test_if_unless_modifier_not_applied
    # Modifier-form conversion is handled by ControlFlowSimplify, not Preprocessor.
    code = "if condition\n  do_something\nend\n"
    assert_equal code, preprocess(code)
  end

  def test_unless_else_rewritten
    assert_equal "if x\n  b\nelse\n  a\nend\n", preprocess("unless x\n  a\nelse\n  b\nend\n")
  end

  # %w[] does not honour `#` comments, so a note written inside COPS silently
  # becomes cop names — which is how Style/SendWithLiteralMethodName ended up
  # enabled by the very comment saying it was excluded. Entries that do not
  # resolve are dropped by filter_map, so nothing else would report this.
  def test_every_configured_cop_resolves
    unresolved = Ryac::Pipeline::Preprocessor::COPS.reject do |name|
      RuboCop::Cop::Registry.global.find_by_cop_name(name)
    end
    assert_empty unresolved, "COPS contains entries that are not RuboCop cops"
  end

  # These rewrite `x.count == 0` / `x.any?` on the assumption the receiver is a
  # collection. RuboCop marks them Safe=false and they broke a real program
  # (optcarrot's APU::LengthCounter#count is a plain attr_reader).
  def test_collection_assuming_cops_stay_disabled
    %w[Style/ZeroLengthPredicate Style/CollectionQuerying].each do |cop|
      refute_includes Ryac::Pipeline::Preprocessor::COPS, cop
    end
  end

  def test_count_zero_comparison_left_alone
    code = "def active?\n  @length_counter.count == 0\nend\n"
    assert_equal code, preprocess(code)
  end
end
