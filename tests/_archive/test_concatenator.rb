# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/ryac/pipeline/stage'
require_relative '../lib/ryac/pipeline/data_types'
require_relative '../lib/ryac/pipeline/errors'
require_relative '../lib/ryac/pipeline/concatenator'

class TestConcatenator < Minitest::Test
  def setup
    @concatenator = Ryac::Pipeline::Concatenator.new
  end

  # T011: Basic concatenation test
  def test_concatenates_files_in_dependency_order
    graph = create_simple_graph

    result = @concatenator.call(graph)

    assert_instance_of Ryac::Pipeline::ConcatenatedSource, result
    refute_empty result.content
  end

  def test_dependencies_appear_before_dependents
    graph = create_simple_graph

    result = @concatenator.call(graph)
    content = result.content

    # dependency.rb should appear before entry.rb
    dep_pos = content.index('module Dependency')
    entry_pos = content.index('module Entry')

    assert dep_pos, "Dependency module should be in output"
    assert entry_pos, "Entry module should be in output"
    assert dep_pos < entry_pos, "Dependency should appear before Entry"
  end

  def test_removes_require_relative_statements
    graph = create_graph_with_require

    result = @concatenator.call(graph)

    refute_includes result.content, "require_relative"
  end

  def test_tracks_file_boundaries
    graph = create_simple_graph

    result = @concatenator.call(graph)

    assert_instance_of Array, result.file_boundaries
    assert_equal 2, result.file_boundaries.size
  end

  def test_calculates_original_size
    graph = create_simple_graph

    result = @concatenator.call(graph)

    total_size = graph.files.values.sum { |f| f.content.bytesize }
    assert_equal total_size, result.original_size
  end

  private

  def create_simple_graph
    graph = Ryac::Pipeline::DependencyGraph.new

    dep_entry = Ryac::Pipeline::FileEntry.new(
      path: '/fake/dependency.rb',
      content: "module Dependency\n  def helper; end\nend",
      dependencies: [],
      require_nodes: []
    )

    entry_entry = Ryac::Pipeline::FileEntry.new(
      path: '/fake/entry.rb',
      content: "module Entry\n  include Dependency\nend",
      dependencies: ['/fake/dependency.rb'],
      require_nodes: []
    )

    graph.add_file(dep_entry)
    graph.add_file(entry_entry)
    graph
  end

  def create_graph_with_require
    graph = Ryac::Pipeline::DependencyGraph.new

    dep_entry = Ryac::Pipeline::FileEntry.new(
      path: '/fake/dependency.rb',
      content: "module Dependency\n  def helper; end\nend",
      dependencies: [],
      require_nodes: []
    )

    entry_entry = Ryac::Pipeline::FileEntry.new(
      path: '/fake/entry.rb',
      content: "require_relative 'dependency'\nmodule Entry\n  include Dependency\nend",
      dependencies: ['/fake/dependency.rb'],
      require_nodes: [{ type: :require_relative, path: 'dependency', line: 1 }]
    )

    graph.add_file(dep_entry)
    graph.add_file(entry_entry)
    graph
  end

  # T020: Circular dependency detection test
  def test_detects_circular_dependency
    graph = create_circular_graph

    assert_raises Ryac::Pipeline::CircularDependencyError do
      @concatenator.call(graph)
    end
  end

  def test_circular_dependency_error_contains_cycle
    graph = create_circular_graph

    error = assert_raises Ryac::Pipeline::CircularDependencyError do
      @concatenator.call(graph)
    end

    assert_instance_of Array, error.cycle
    refute_empty error.cycle
  end

  # T022: Stdlib require preservation test
  def test_preserves_stdlib_requires
    graph = create_graph_with_stdlib

    result = @concatenator.call(graph)

    assert_includes result.stdlib_requires, 'json'
  end

  def create_circular_graph
    graph = Ryac::Pipeline::DependencyGraph.new

    a_entry = Ryac::Pipeline::FileEntry.new(
      path: '/fake/a.rb',
      content: "require_relative 'b'\nmodule A; end",
      dependencies: ['/fake/b.rb'],
      require_nodes: [{ type: :require_relative, path: 'b', line: 1 }]
    )

    b_entry = Ryac::Pipeline::FileEntry.new(
      path: '/fake/b.rb',
      content: "require_relative 'a'\nmodule B; end",
      dependencies: ['/fake/a.rb'],
      require_nodes: [{ type: :require_relative, path: 'a', line: 1 }]
    )

    graph.add_file(a_entry)
    graph.add_file(b_entry)
    graph
  end

  def create_graph_with_stdlib
    graph = Ryac::Pipeline::DependencyGraph.new

    entry = Ryac::Pipeline::FileEntry.new(
      path: '/fake/entry.rb',
      content: "require 'json'\nmodule Entry; end",
      dependencies: [],
      require_nodes: [{ type: :require_stdlib, path: 'json', line: 1 }]
    )

    graph.add_file(entry)
    graph
  end
end
