# frozen_string_literal: true

require_relative '../../test_helper'

class TestConcatenator < Minitest::Test
  def setup
    @concatenator = RubyMinify::Pipeline::Concatenator.new
  end

  def test_single_file
    graph = build_graph(
      "/a.rb" => { content: "puts 1", deps: [] }
    )
    result = @concatenator.call(graph)
    assert_equal "puts 1", result.content
    assert_equal 1, result.file_boundaries.size
    assert_equal "/a.rb", result.file_boundaries.first.path
  end

  def test_dependency_order
    graph = build_graph(
      "/a.rb" => { content: "A", deps: [] },
      "/b.rb" => { content: "B", deps: ["/a.rb"] }
    )
    result = @concatenator.call(graph)
    # a should come before b (b depends on a)
    assert_equal "A\nB", result.content
  end

  def test_three_file_chain
    graph = build_graph(
      "/a.rb" => { content: "A", deps: [] },
      "/b.rb" => { content: "B", deps: ["/a.rb"] },
      "/c.rb" => { content: "C", deps: ["/b.rb"] }
    )
    result = @concatenator.call(graph)
    assert_equal "A\nB\nC", result.content
  end

  def test_circular_dependency_raises
    graph = build_graph(
      "/a.rb" => { content: "A", deps: ["/b.rb"] },
      "/b.rb" => { content: "B", deps: ["/a.rb"] }
    )
    assert_raises(RubyMinify::Pipeline::CircularDependencyError) do
      @concatenator.call(graph)
    end
  end

  def test_file_boundaries_line_tracking
    graph = build_graph(
      "/a.rb" => { content: "line1\nline2", deps: [] },
      "/b.rb" => { content: "line3", deps: ["/a.rb"] }
    )
    result = @concatenator.call(graph)
    bounds = result.file_boundaries
    assert_equal 2, bounds.size
    assert_equal 1, bounds[0].start_line
    assert_equal 2, bounds[0].end_line
    assert_equal 3, bounds[1].start_line
    assert_equal 3, bounds[1].end_line
  end

  def test_original_size
    graph = build_graph(
      "/a.rb" => { content: "AAA", deps: [] },
      "/b.rb" => { content: "BB", deps: [] }
    )
    result = @concatenator.call(graph)
    assert_equal 5, result.original_size
  end

  def test_stdlib_requires_collected
    graph = build_graph(
      "/a.rb" => { content: "require 'json'\nputs 1", deps: [],
                    require_nodes: [{ type: :require_stdlib, path: "json", line: 1 }] }
    )
    result = @concatenator.call(graph)
    assert_equal ["json"], result.stdlib_requires
  end

  def test_stdlib_requires_deduplicated
    graph = build_graph(
      "/a.rb" => { content: "require 'json'", deps: [],
                    require_nodes: [{ type: :require_stdlib, path: "json", line: 1 }] },
      "/b.rb" => { content: "require 'json'", deps: [],
                    require_nodes: [{ type: :require_stdlib, path: "json", line: 1 }] }
    )
    result = @concatenator.call(graph)
    assert_equal 1, result.stdlib_requires.count("json")
  end

  def test_require_statements_removed_line_based
    graph = build_graph(
      "/a.rb" => { content: "require_relative 'b'\nputs 1", deps: ["/b.rb"],
                    require_nodes: [{ type: :require_relative, path: "/b.rb", line: 1 }] },
      "/b.rb" => { content: "B = 1", deps: [] }
    )
    result = @concatenator.call(graph)
    assert_equal "B = 1\n\nputs 1", result.content
  end

  def test_in_class_dependency_inlined_with_nesting_stripped
    # When a file is required inside a class body, its content should be
    # inlined with outer module/class nesting stripped.
    helper_content = "module Outer\n  class Widget\n    class Helper\n      def help; end\n    end\n  end\nend"
    graph = build_graph(
      "/widget/helper.rb" => { content: helper_content, deps: [] },
      "/widget.rb" => {
        content: "module Outer\n  class Widget < Base\n    require_relative 'widget/helper'\n    def run; end\n  end\nend",
        deps: [], in_class_deps: ["/widget/helper.rb"],
        require_nodes: [{ type: :require_relative, path: "widget/helper",
                          line: 3, start_offset: 38, length: 33, in_class: true,
                          resolved_path: "/widget/helper.rb" }]
      }
    )
    result = @concatenator.call(graph)
    assert_equal "module Outer\n  class Widget < Base\n   class Helper\n      def help; end\n    end\n    def run; end\n  end\nend", result.content
    assert_equal 1, result.file_boundaries.size
  end

  def test_in_class_dep_with_own_dependency
    # C is required at top-level by B. B is required in-class by A.
    # C should appear standalone, B inlined into A (with nesting stripped).
    b_content = "class A\n  module B\n    X = 1\n  end\nend"
    graph = build_graph(
      "/c.rb" => { content: "C", deps: [] },
      "/b.rb" => { content: b_content, deps: ["/c.rb"] },
      "/a.rb" => {
        content: "class A\n  require_relative 'b'\n  include B\nend",
        deps: [], in_class_deps: ["/b.rb"],
        require_nodes: [{ type: :require_relative, path: "b",
                          line: 2, start_offset: 10, length: 20, in_class: true,
                          resolved_path: "/b.rb" }]
      }
    )
    result = @concatenator.call(graph)
    assert_equal "C\nclass A\n  module B\n    X = 1\n  end\n  include B\nend", result.content
  end

  def test_circular_dependency_with_non_cycle_node
    # Non-cycle node /c.rb is explored first by DFS without finding a cycle,
    # exercising the backtracking path (rec_stack.delete, path.pop, return false)
    graph = build_graph(
      "/c.rb" => { content: "C", deps: [] },
      "/a.rb" => { content: "A", deps: ["/b.rb"] },
      "/b.rb" => { content: "B", deps: ["/a.rb"] }
    )
    err = assert_raises(RubyMinify::Pipeline::CircularDependencyError) do
      @concatenator.call(graph)
    end
    assert_equal ["/a.rb", "/b.rb", "/a.rb"], err.cycle
  end

  def test_in_class_require_with_trailing_semicolon
    helper_content = "module M\n  class H\n    def h; end\n  end\nend"
    main_content = "module M\n  class W\n    require_relative \"h\";def run; end\n  end\nend"
    graph = build_graph(
      "/h.rb" => { content: helper_content, deps: [] },
      "/w.rb" => {
        content: main_content, deps: [], in_class_deps: ["/h.rb"],
        require_nodes: [{ type: :require_relative, path: "h",
                          line: 3, start_offset: 23, length: 20, in_class: true,
                          resolved_path: "/h.rb" }]
      }
    )
    result = @concatenator.call(graph)
    assert_equal "module M\n  class W\n    class H\n    def h; end\n  enddef run; end\n  end\nend", result.content
    assert_equal 1, result.file_boundaries.size
  end

  def test_offset_based_require_removal_with_trailing_semicolon_and_newline
    graph = build_graph(
      "/b.rb" => { content: "B = 1", deps: [] },
      "/a.rb" => {
        content: "require_relative \"b\";\nputs 1",
        deps: ["/b.rb"],
        require_nodes: [{ type: :require_relative, path: "b",
                          line: 1, start_offset: 0, length: 20 }]
      }
    )
    result = @concatenator.call(graph)
    assert_equal "B = 1\nputs 1", result.content
  end

  def test_rbs_files_passed_through
    graph = build_graph(
      "/a.rb" => { content: "A", deps: [] }
    )
    graph.rbs_files["/a.rbs"] = "class A; end"
    result = @concatenator.call(graph)
    assert_equal({ "/a.rbs" => "class A; end" }, result.rbs_files)
  end

  # A require inside a method body runs only when that method is called, and is
  # usually guarded — optcarrot requires stackprof only under --stackprof-mode.
  # Hoisting it to the top of the output would make an optional dependency
  # mandatory, so it has to stay inline and out of stdlib_requires.
  def test_in_method_stdlib_require_stays_inline
    content = "class R\n  def run\n    if @profile\n      require \"stackprof\"\n    end\n  end\nend"
    graph = build_graph(
      "/r.rb" => {
        content: content,
        deps: [],
        require_nodes: [{
          type: :require_stdlib,
          path: "stackprof",
          line: 4,
          start_offset: content.index('require "stackprof"'),
          length: 'require "stackprof"'.length,
          in_class: true,
          in_method: true
        }]
      }
    )
    result = @concatenator.call(graph)
    assert_empty result.stdlib_requires, "in-method require must not be hoisted"
    assert_includes result.content, 'require "stackprof"', "in-method require must stay in place"
  end

  def test_top_level_stdlib_require_still_hoisted
    content = "require \"zlib\"\nclass R\nend"
    graph = build_graph(
      "/r.rb" => {
        content: content,
        deps: [],
        require_nodes: [{
          type: :require_stdlib,
          path: "zlib",
          line: 1,
          start_offset: 0,
          length: 'require "zlib"'.length,
          in_class: false,
          in_method: false
        }]
      }
    )
    result = @concatenator.call(graph)
    assert_equal ["zlib"], result.stdlib_requires
    refute_includes result.content, 'require "zlib"'
  end

  def test_autoload_declaration_removed_when_dependency_inlined
    formatter_content = "module MyLib\n  class Formatter\n    def format(text)\n      text.upcase\n    end\n  end\nend"
    main_content = "module MyLib\n  autoload :Formatter, \"my_lib/formatter\"\n\n  class Runner\n    def run\n      Formatter.new.format(\"hello\")\n    end\n  end\nend"
    graph = build_graph(
      "/my_lib/formatter.rb" => { content: formatter_content, deps: [] },
      "/main.rb" => {
        content: main_content,
        deps: [], in_class_deps: ["/my_lib/formatter.rb"],
        require_nodes: [{ type: :autoload, path: "my_lib/formatter",
                          line: 2, start_offset: 15, length: 39, in_class: true,
                          resolved_path: "/my_lib/formatter.rb" }]
      }
    )
    result = @concatenator.call(graph)
    expected = "module MyLib\n  class Formatter\n    def format(text)\n      text.upcase\n    end\n  end\n\n  class Runner\n    def run\n      Formatter.new.format(\"hello\")\n    end\n  end\nend"
    assert_equal expected, result.content
  end

  def test_autoload_top_level_removed
    formatter_content = "class Formatter; end"
    main_content = "autoload :Formatter, \"formatter\"\nputs 1"
    graph = build_graph(
      "/formatter.rb" => { content: formatter_content, deps: [] },
      "/main.rb" => {
        content: main_content,
        deps: ["/formatter.rb"],
        require_nodes: [{ type: :autoload, path: "formatter",
                          line: 1, start_offset: 0, length: 32,
                          resolved_path: "/formatter.rb" }]
      }
    )
    result = @concatenator.call(graph)
    assert_equal "class Formatter; end\nputs 1", result.content
  end

  private

  def build_graph(files)
    graph = RubyMinify::Pipeline::DependencyGraph.new
    files.each do |path, info|
      entry = RubyMinify::Pipeline::FileEntry.new(
        path: path.to_s,
        content: info[:content],
        dependencies: info[:deps] || [],
        require_nodes: info[:require_nodes] || [],
        in_class_dependencies: info[:in_class_deps] || []
      )
      graph.add_file(entry)
    end
    graph
  end
end
