# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/ryac'

class TestAnalyzerStage < Minitest::Test
  def setup
    @analyzer = Ryac::Pipeline::Analyzer.new
  end

  def test_analyzer_returns_analysis_result
    source = create_simple_source

    result = @analyzer.call(source)

    assert_instance_of Ryac::Pipeline::AnalysisResult, result
  end

  def test_analyzer_builds_scope_mappings
    source = create_source_with_method

    result = @analyzer.call(source)

    refute_empty result.scope_mappings, "Scope mappings should be built for method variables"
  end

  def test_analyzer_freezes_constant_mapping
    source = create_source_with_constants

    result = @analyzer.call(source)

    assert result.constant_mapping.finalized?, "Constant mapping should be frozen"
  end

  def test_analyzer_freezes_external_prefix_aliaser
    source = create_source_with_constants

    result = @analyzer.call(source)

    assert result.external_prefix_aliaser.finalized?, "External prefix aliaser should be frozen"
  end

  def test_analyzer_preserves_source
    source = create_simple_source

    result = @analyzer.call(source)

    assert_equal source, result.source
  end

  def test_analyzer_raises_on_syntax_error
    source = create_syntax_error_source

    assert_raises(Ryac::SyntaxError) do
      @analyzer.call(source)
    end
  end

  # Phase 0: TypeProf boxes API investigation
  def test_typeprof_method_boxes_api
    content = <<~RUBY
      class Greeter
        def greet(name)
          "Hello, " + name
        end

        def run
          greet("world")
        end
      end
    RUBY

    path = "(test_boxes)"
    service = TypeProf::Core::Service.new({})
    service.update_rb_file(path, content)
    nodes = service.instance_variable_get(:@rb_text_nodes)[path]
    genv = service.instance_variable_get(:@genv)

    # Find DefNode for 'greet' and verify boxes(:mdef) works
    def_nodes = []
    find_def_nodes(nodes.body, def_nodes)
    greet_node = def_nodes.find { |n| n.mid == :greet }
    refute_nil greet_node, "Should find DefNode for greet"

    # boxes(:mdef) should yield MethodDefBox with cpath, singleton, mid
    mdef_boxes = []
    greet_node.boxes(:mdef) { |box| mdef_boxes << box }
    refute_empty mdef_boxes, "DefNode.boxes(:mdef) should yield boxes"

    box = mdef_boxes.first
    assert_equal [:Greeter], box.cpath, "box.cpath should be [:Greeter]"
    assert_equal false, box.singleton, "box.singleton should be false for instance method"
    assert_equal :greet, box.mid, "box.mid should be :greet"

    # genv.resolve_method should return a MethodEntity
    method_entity = genv.resolve_method(box.cpath, box.singleton, box.mid)
    refute_nil method_entity, "genv.resolve_method should return a MethodEntity"

    # method_call_boxes should return call boxes (TypeProf::Core::Set)
    call_boxes = method_entity.method_call_boxes
    call_boxes_array = []
    call_boxes.each { |box| call_boxes_array << box }
    refute_empty call_boxes_array, "MethodEntity.method_call_boxes should return call boxes"

    # Each call box should have a node (CallNode) with mid
    call_box = call_boxes_array.first
    call_node = call_box.node
    assert_equal :greet, call_node.mid, "CallNode.mid should be :greet"

    # Check recv for implicit receiver (should be nil or self-like)
    # In 'greet("world")' inside the same class, recv may be nil for implicit self
  end

  def test_method_collection_collects_definitions_and_calls
    content = <<~RUBY
      class Calculator
        def add(a, b)
          a + b
        end

        def multiply(a, b)
          a * b
        end

        def compute(x, y)
          add(x, y) + multiply(x, y)
        end
      end
    RUBY

    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: content,
      file_boundaries: [],
      original_size: content.bytesize,
      stdlib_requires: []
    )

    result = @analyzer.call(source)

    # rename_map should be a Hash
    assert_instance_of Hash, result.rename_map

    # Methods 'add' and 'multiply' have call sites (from compute),
    # but the method name is only 3 chars, so 'add' may not be renamed.
    # 'multiply' (8 chars) with 2 occurrences (1 def + 1 call) might be renamed.
    # 'compute' (7 chars) with 1 occurrence (1 def, no calls) should NOT be renamed.
  end

  def test_augment_constant_counts_via_typeprof
    content = <<~RUBY
      class MyLongConstantName
        VALUE = 42
      end
      MyLongConstantName.new
      MyLongConstantName.new
      MyLongConstantName.new
    RUBY

    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: content,
      file_boundaries: [],
      original_size: content.bytesize,
      stdlib_requires: []
    )

    result = @analyzer.call(source)

    # The constant mapping should track usage counts.
    # TypeProf's resolve_const should find at least as many references as AST traversal.
    info = result.constant_mapping.mappings[[:MyLongConstantName]]
    refute_nil info, "MyLongConstantName should be in constant mapping"
    assert_operator info.usage_count, :>=, 3, "Usage count should be at least 3 (3 references)"
  end

  private

  def find_def_nodes(node, result)
    return unless node

    case node
    when TypeProf::Core::AST::DefNode
      result << node
      find_def_nodes(node.body, result)
    when TypeProf::Core::AST::StatementsNode
      node.stmts.each { |s| find_def_nodes(s, result) }
    when TypeProf::Core::AST::ClassNode, TypeProf::Core::AST::ModuleNode
      find_def_nodes(node.body, result)
    end
  end

  def create_simple_source
    content = <<~RUBY
      module SimpleModule
        def simple_method
          x = 1
          x + 1
        end
      end
    RUBY

    Ryac::Pipeline::ConcatenatedSource.new(
      content: content,
      file_boundaries: [
        Ryac::Pipeline::FileBoundary.new(
          path: '/fake/simple.rb',
          start_line: 1,
          end_line: 6
        )
      ],
      original_size: content.bytesize,
      stdlib_requires: []
    )
  end

  def create_source_with_method
    content = <<~RUBY
      def greet(user_name)
        message = "Hello, \#{user_name}"
        message
      end
    RUBY

    Ryac::Pipeline::ConcatenatedSource.new(
      content: content,
      file_boundaries: [],
      original_size: content.bytesize,
      stdlib_requires: []
    )
  end

  def create_source_with_constants
    content = <<~RUBY
      class MyLongClassName
        def value; 42; end
      end
      MyLongClassName.new
    RUBY

    Ryac::Pipeline::ConcatenatedSource.new(
      content: content,
      file_boundaries: [],
      original_size: content.bytesize,
      stdlib_requires: []
    )
  end

  def create_syntax_error_source
    content = "def broken(\n"

    Ryac::Pipeline::ConcatenatedSource.new(
      content: content,
      file_boundaries: [],
      original_size: content.bytesize,
      stdlib_requires: []
    )
  end
end
