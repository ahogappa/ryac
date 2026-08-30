# frozen_string_literal: true

require_relative '../../test_helper'

class TestDataTypes < Minitest::Test
  def test_file_entry_attributes
    entry = Ryac::Pipeline::FileEntry.new(
      path: "/tmp/foo.rb",
      content: "puts 1",
      dependencies: ["/tmp/bar.rb"],
      require_nodes: []
    )
    assert_equal "/tmp/foo.rb", entry.path
    assert_equal "puts 1", entry.content
    assert_equal ["/tmp/bar.rb"], entry.dependencies
    assert_equal [], entry.require_nodes
    assert_equal [], entry.in_class_dependencies
  end

  def test_file_entry_with_in_class_dependencies
    entry = Ryac::Pipeline::FileEntry.new(
      path: "/tmp/foo.rb",
      content: "puts 1",
      dependencies: [],
      require_nodes: [],
      in_class_dependencies: ["/tmp/bar.rb"]
    )
    assert_equal ["/tmp/bar.rb"], entry.in_class_dependencies
  end

  def test_dependency_graph_add_and_lookup
    graph = Ryac::Pipeline::DependencyGraph.new
    entry = Ryac::Pipeline::FileEntry.new(
      path: "/tmp/a.rb", content: "A", dependencies: [], require_nodes: []
    )
    graph.add_file(entry)
    assert_equal entry, graph["/tmp/a.rb"]
    assert_equal ["/tmp/a.rb"], graph.paths
    assert_equal 1, graph.size
    refute graph.empty?
  end

  def test_dependency_graph_empty
    graph = Ryac::Pipeline::DependencyGraph.new
    assert graph.empty?
    assert_equal 0, graph.size
  end

  def test_dependency_graph_adjacency
    graph = Ryac::Pipeline::DependencyGraph.new
    a = Ryac::Pipeline::FileEntry.new(
      path: "/a.rb", content: "A", dependencies: [], require_nodes: []
    )
    b = Ryac::Pipeline::FileEntry.new(
      path: "/b.rb", content: "B", dependencies: ["/a.rb"], require_nodes: []
    )
    graph.add_file(a)
    graph.add_file(b)
    # a → b (b depends on a, so a's adjacency includes b)
    assert_equal ["/b.rb"], graph.adjacency["/a.rb"]
    assert_equal 0, graph.in_degrees["/a.rb"]
    assert_equal 1, graph.in_degrees["/b.rb"]
  end

  def test_dependency_graph_in_class_dependencies
    graph = Ryac::Pipeline::DependencyGraph.new
    a = Ryac::Pipeline::FileEntry.new(
      path: "/a.rb", content: "A", dependencies: [], require_nodes: []
    )
    b = Ryac::Pipeline::FileEntry.new(
      path: "/b.rb", content: "B", dependencies: [], require_nodes: [],
      in_class_dependencies: ["/a.rb"]
    )
    graph.add_file(a)
    graph.add_file(b)
    assert_equal ["/b.rb"], graph.adjacency["/a.rb"]
    assert_equal 0, graph.in_degrees["/a.rb"]
    assert_equal 1, graph.in_degrees["/b.rb"]
  end

  def test_dependency_graph_rbs_files
    graph = Ryac::Pipeline::DependencyGraph.new
    assert_equal({}, graph.rbs_files)
  end

  def test_file_boundary
    fb = Ryac::Pipeline::FileBoundary.new(path: "/foo.rb", start_line: 1, end_line: 10)
    assert_equal "/foo.rb", fb.path
    assert_equal 1, fb.start_line
    assert_equal 10, fb.end_line
  end

  def test_concatenated_source_defaults
    cs = Ryac::Pipeline::ConcatenatedSource.new(
      content: "code", file_boundaries: [], original_size: 100, stdlib_requires: []
    )
    assert_equal "code", cs.content
    assert_equal({}, cs.rbs_files)
  end

  def test_concatenated_source_synthetic_defaults
    cs = Ryac::Pipeline::ConcatenatedSource.new(content: "x = 1")
    assert_equal [], cs.file_boundaries
    assert_equal "x = 1".bytesize, cs.original_size
    assert_equal [], cs.stdlib_requires
    assert_equal({}, cs.rbs_files)
  end

  def test_concatenated_source_with_preserves_provenance
    fb = Ryac::Pipeline::FileBoundary.new(path: "/a.rb", start_line: 1, end_line: 3)
    cs = Ryac::Pipeline::ConcatenatedSource.new(
      content: "long original text", file_boundaries: [fb],
      original_size: 500, stdlib_requires: ["json"], rbs_files: { "a.rbs" => "class A end" }
    )
    rebuilt = cs.with(content: "short")
    assert_equal "short", rebuilt.content
    # The rewritten text must not overwrite what describes the collected input.
    assert_equal 500, rebuilt.original_size
    assert_equal [fb], rebuilt.file_boundaries
    assert_equal ["json"], rebuilt.stdlib_requires
    assert_equal({ "a.rbs" => "class A end" }, rebuilt.rbs_files)
  end

  def test_rename_result_defaults
    rr = Ryac::Pipeline::RenameResult.new(code: "x=1")
    assert_equal "x=1", rr.code
    assert_equal "", rr.aliases
  end

  def test_rename_result_preamble_default
    rr = Ryac::Pipeline::RenameResult.new(code: "x=1")
    assert_equal "", rr.preamble
  end

  def test_rename_result_with_aliases
    rr = Ryac::Pipeline::RenameResult.new(code: "x=1", aliases: "Foo=A")
    assert_equal "Foo=A", rr.aliases
  end

  def test_rename_result_with_preamble
    rr = Ryac::Pipeline::RenameResult.new(code: "x=1", preamble: "A=Process")
    assert_equal "A=Process", rr.preamble
  end

  def test_compression_stats
    stats = Ryac::Pipeline::CompressionStats.new(
      original_size: 1000, minified_size: 500, compression_ratio: 0.5, file_count: 3
    )
    assert_equal 1000, stats.original_size
    assert_equal 500, stats.minified_size
    assert_equal 0.5, stats.compression_ratio
    assert_equal 3, stats.file_count
  end

  def test_minified_result_defaults
    stats = Ryac::Pipeline::CompressionStats.new(
      original_size: 100, minified_size: 50, compression_ratio: 0.5, file_count: 1
    )
    mr = Ryac::Pipeline::MinifiedResult.new(content: "code", stats: stats)
    assert_equal "code", mr.content
    assert_equal "", mr.aliases
    assert_equal "", mr.preamble
    assert_equal stats, mr.stats
  end

  def test_minified_result_with_aliases_and_preamble
    stats = Ryac::Pipeline::CompressionStats.new(
      original_size: 100, minified_size: 50, compression_ratio: 0.5, file_count: 1
    )
    mr = Ryac::Pipeline::MinifiedResult.new(
      content: "code", aliases: "Foo=A", preamble: "A=Process", stats: stats
    )
    assert_equal "Foo=A", mr.aliases
    assert_equal "A=Process", mr.preamble
  end

  def test_minified_result_full_content_attaches_aliases
    stats = Ryac::Pipeline::CompressionStats.new(
      original_size: 100, minified_size: 50, compression_ratio: 0.5, file_count: 1
    )
    with_aliases = Ryac::Pipeline::MinifiedResult.new(
      content: "A=Process;code", aliases: "Foo=A", preamble: "A=Process", stats: stats
    )
    assert_equal "A=Process;code;Foo=A", with_aliases.full_content

    without = Ryac::Pipeline::MinifiedResult.new(content: "code", stats: stats)
    assert_equal "code", without.full_content
  end

  def test_analysis_result_defaults
    ar = Ryac::Pipeline::AnalysisResult.new(
      prism_ast: nil, scope_mappings: {}, constant_mapping: nil,
      rename_map: {}, method_alias_map: {},
      method_transform_map: {}, source: nil, attr_rename_map: {},
      block_param_names_map: {}, syntax_data: {}, const_resolution_map: {},
      const_full_path_map: {}, const_write_cpath_map: {}, class_cpath_map: {},
      superclass_resolution_map: {}, meta_node_map: {}
    )
    assert_equal({}, ar.local_rename_entries)
    assert_equal({}, ar.keyword_rename_entries)
    assert_equal({}, ar.ivar_rename_entries)
    assert_equal({}, ar.attr_ivar_entries)
    assert_equal({}, ar.cvar_rename_entries)
    assert_equal({}, ar.gvar_rename_entries)
  end
end
