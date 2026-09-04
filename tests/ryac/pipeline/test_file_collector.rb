# frozen_string_literal: true

require_relative '../../test_helper'

class TestFileCollector < Minitest::Test
  # A broken input file must fail at collection, named and located —
  # not three stages later as a nameless internal error.
  def test_syntax_error_names_the_file_and_position
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'broken.rb')
      File.write(path, "def f(\nend\n")
      err = assert_raises(Ryac::SyntaxError) { Ryac::Pipeline::FileCollector.new.call(path) }
      assert_equal path, err.path
      assert_equal 2, err.line
      assert_equal "#{path}:2:0: unexpected 'end'; expected a `)` to close the parameters", err.message
    end
  end

  def test_input_and_internal_errors_split_under_one_root
    assert_operator Ryac::Pipeline::StageError, :<, Ryac::InputError
    assert_operator Ryac::Pipeline::InvalidOutputError, :<, Ryac::InternalError
    assert_operator Ryac::Pipeline::RenameCollisionError, :<, Ryac::InternalError
    assert_operator Ryac::SyntaxError, :<, Ryac::InputError
    assert_operator Ryac::MinifyError, :<, Ryac::InputError
    [Ryac::InputError, Ryac::InternalError].each { |c| assert_operator c, :<, Ryac::Error }
  end

  def setup
    @collector = Ryac::Pipeline::FileCollector.new
    @fixtures_dir = File.expand_path('../../fixtures/multi_file', __dir__)
  end

  def test_dynamic_require_inside_method_is_skipped
    entry_path = File.join(@fixtures_dir, 'dynamic_require_in_method.rb')
    graph = @collector.call(entry_path)

    # Should collect entry file and dependency_a without raising DynamicRequireError
    assert graph[entry_path]
    dep_a_path = File.join(@fixtures_dir, 'lib', 'dependency_a.rb')
    assert graph[dep_a_path]
    assert_equal [], graph.lazy_paths
  end

  # A dynamic require under a static directory bundles every file there as
  # a lazy region, and what those files require that nothing static did
  # comes along lazily too; the static world stays flat.
  def test_dynamic_require_under_a_static_directory_collects_lazy_files
    fixture_dir = File.expand_path('../../fixtures/lazy_plugins', __dir__)
    entry_path = File.join(fixture_dir, 'main.rb')
    loader_path = File.join(fixture_dir, 'engine', 'loader.rb')
    plugins = %w[plain_video shared turbo_video].map { |n| File.join(fixture_dir, 'engine', 'plugins', "#{n}.rb") }

    graph = @collector.call(entry_path)

    assert_equal plugins, graph.lazy_paths
    refute graph[entry_path].lazy
    refute graph[loader_path].lazy

    site = graph[loader_path].require_nodes.fetch(0)
    assert_equal :require_lazy, site[:type]
    assert_equal 'plugins/', site[:path]
    assert site[:in_method]
    assert_equal File.join(fixture_dir, 'engine', 'plugins'), site[:lazy][:dir]
    assert_nil site[:lazy][:suffix_start_offset]

    plain, shared, = plugins
    assert_equal [shared], graph[plain].dependencies
  end

  def test_in_class_require_marks_in_class_flag
    entry_path = File.join(@fixtures_dir, 'in_class_require', 'widget.rb')
    graph = @collector.call(entry_path)

    entry = graph[entry_path]
    # The require_relative inside the class body should be marked in_class
    in_class_nodes = entry.require_nodes.select { |n| n[:in_class] }
    assert_equal 1, in_class_nodes.size
    assert_equal 'widget/helper', in_class_nodes.first[:path]
  end

  def test_in_class_require_tracks_in_class_dependencies
    entry_path = File.join(@fixtures_dir, 'in_class_require', 'widget.rb')
    graph = @collector.call(entry_path)

    entry = graph[entry_path]
    helper_path = File.join(@fixtures_dir, 'in_class_require', 'widget', 'helper.rb')
    assert_equal [helper_path], entry.in_class_dependencies
    # Normal dependencies should NOT include in-class deps
    assert_equal [], entry.dependencies
  end

  def test_dynamic_require_at_top_level_raises
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), <<~RUBY)
        name = "foo"
        require_relative name
      RUBY

      assert_raises Ryac::Pipeline::DynamicRequireError do
        @collector.call(File.join(tmpdir, 'entry.rb'))
      end
    end
  end

  def test_bare_require_resolves_project_local_file
    # `require "foo"` where foo is on $LOAD_PATH and under project root
    # should be collected as a project-local dependency, not skipped as stdlib.
    Dir.mktmpdir do |tmpdir|
      lib_dir = File.join(tmpdir, 'lib')
      Dir.mkdir(lib_dir)
      File.write(File.join(lib_dir, 'helper.rb'), 'HELPER = 1')
      File.write(File.join(tmpdir, 'entry.rb'), 'require "helper"')
      File.write(File.join(tmpdir, 'Gemfile'), '')

      $LOAD_PATH.unshift(lib_dir)
      begin
        graph = @collector.call(File.join(tmpdir, 'entry.rb'))
        helper_path = File.join(lib_dir, 'helper.rb')
        assert graph[helper_path], "Project-local bare require should be collected"
        entry = graph[File.join(tmpdir, 'entry.rb')]
        assert_equal [helper_path], entry.dependencies
      ensure
        $LOAD_PATH.delete(lib_dir)
      end
    end
  end

  def test_bare_require_outside_project_treated_as_stdlib
    # `require "json"` resolves to a path outside the project root → stdlib
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), 'require "json"')
      File.write(File.join(tmpdir, 'Gemfile'), '')

      graph = @collector.call(File.join(tmpdir, 'entry.rb'))
      entry = graph[File.join(tmpdir, 'entry.rb')]
      # json should be tracked as stdlib, not as a dependency
      assert_empty entry.dependencies
      stdlib_nodes = entry.require_nodes.select { |n| n[:type] == :require_stdlib }
      assert_equal 1, stdlib_nodes.size
    end
  end

  def test_require_nodes_have_resolved_path
    entry_path = File.join(@fixtures_dir, 'in_class_require', 'widget.rb')
    graph = @collector.call(entry_path)

    entry = graph[entry_path]
    require_nodes = entry.require_nodes.select { |n| n[:type] != :require_stdlib }
    require_nodes.each do |node|
      assert node[:resolved_path], "require node should have resolved_path: #{node.inspect}"
      assert File.exist?(node[:resolved_path]), "resolved_path should point to existing file"
    end
  end

  def test_nil_input_raises_no_files_error
    assert_raises Ryac::Pipeline::NoFilesError do
      @collector.call(nil)
    end
  end

  def test_empty_array_raises_no_files_error
    assert_raises Ryac::Pipeline::NoFilesError do
      @collector.call([])
    end
  end

  def test_nonexistent_file_raises_file_not_found_error
    assert_raises Ryac::Pipeline::FileNotFoundError do
      @collector.call('/nonexistent/path/file.rb')
    end
  end

  def test_recursive_dependency_collection
    entry_path = File.join(@fixtures_dir, 'entry.rb')
    graph = @collector.call(entry_path)

    dep_a = File.join(@fixtures_dir, 'lib', 'dependency_a.rb')
    dep_b = File.join(@fixtures_dir, 'lib', 'dependency_b.rb')
    dep_c = File.join(@fixtures_dir, 'lib', 'nested', 'dependency_c.rb')

    assert graph[entry_path], "entry should be collected"
    assert graph[dep_a], "dependency_a should be collected"
    assert graph[dep_b], "dependency_b should be collected"
    assert graph[dep_c], "nested dependency_c should be collected transitively"
  end

  def test_multiple_entry_paths
    entry_a = File.join(@fixtures_dir, 'independent_a.rb')
    entry_b = File.join(@fixtures_dir, 'independent_b.rb')
    graph = @collector.call([entry_a, entry_b])

    assert graph[entry_a], "first entry should be collected"
    assert graph[entry_b], "second entry should be collected"
  end

  def test_shared_dependency_collected_once
    entry_path = File.join(@fixtures_dir, 'entry.rb')
    sharing_path = File.join(@fixtures_dir, 'entry_sharing_dep.rb')
    graph = @collector.call([entry_path, sharing_path])

    dep_b = File.join(@fixtures_dir, 'lib', 'dependency_b.rb')
    assert graph[dep_b], "shared dependency should be collected"
    # Count how many times dep_b appears in graph.files
    dep_b_count = graph.files.count { |path, _entry| path == dep_b }
    assert_equal 1, dep_b_count, "shared dependency should be collected only once"
  end

  def test_autoload_collects_dependency
    entry_path = File.join(@fixtures_dir, 'autoload_test', 'main.rb')
    graph = @collector.call(entry_path)

    helper_path = File.join(@fixtures_dir, 'autoload_test', 'helper.rb')
    assert graph[entry_path], "entry should be collected"
    assert graph[helper_path], "autoloaded file should be collected"
  end

  def test_autoload_with_bare_require_path_collects_dependency
    fixture_dir = File.join(@fixtures_dir, 'autoload_bare_require_test')
    entry_path = File.join(fixture_dir, 'main.rb')
    formatter_path = File.join(fixture_dir, 'my_lib', 'formatter.rb')

    $LOAD_PATH.unshift(fixture_dir)
    begin
      graph = @collector.call(entry_path, project_root: fixture_dir)
      entry = graph[entry_path]
      autoload_nodes = entry.require_nodes.select { |n| n[:type] == :autoload }
      assert_equal 1, autoload_nodes.size
      assert_equal formatter_path, autoload_nodes.first[:resolved_path]
    ensure
      $LOAD_PATH.delete(fixture_dir)
    end
  end

  def test_autoload_with_dir_interpolation_collects_dependency
    fixture_dir = File.join(@fixtures_dir, 'autoload_dir_test')
    entry_path = File.join(fixture_dir, 'main.rb')
    helper_path = File.join(fixture_dir, 'mixin', 'helper.rb')

    graph = @collector.call(entry_path)
    entry = graph[entry_path]
    autoload_nodes = entry.require_nodes.select { |n| n[:type] == :autoload }
    assert_equal 1, autoload_nodes.size
    assert_equal helper_path, autoload_nodes.first[:resolved_path]
    assert graph[helper_path], "autoloaded file should be collected"
  end

  # The __dir__ exception is exactly one shape; any other interpolation is
  # still dynamic and still fails loudly.
  def test_autoload_with_non_dir_interpolation_raises
    Dir.mktmpdir do |tmpdir|
      entry = File.join(tmpdir, 'entry.rb')
      File.write(entry, <<~'RUBY')
        prefix = 'helper'
        autoload :Helper, "./#{prefix}"
      RUBY

      error = assert_raises Ryac::Pipeline::DynamicRequireError do
        @collector.call(entry)
      end
      assert_equal %(Dynamic require at #{entry}:2: autoload :Helper, "./\#{prefix}"), error.message
    end
  end

  def test_dynamic_autoload_at_top_level_raises
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), <<~RUBY)
        path = './helper'
        autoload :Helper, path
      RUBY

      assert_raises Ryac::Pipeline::DynamicRequireError do
        @collector.call(File.join(tmpdir, 'entry.rb'))
      end
    end
  end

  def test_dynamic_require_at_top_level_raises_for_require
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), <<~RUBY)
        name = "foo"
        require name
      RUBY

      assert_raises Ryac::Pipeline::DynamicRequireError do
        @collector.call(File.join(tmpdir, 'entry.rb'))
      end
    end
  end

  def test_require_with_relative_dot_path
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), 'require "./lib/helper"')
      lib_dir = File.join(tmpdir, 'lib')
      Dir.mkdir(lib_dir)
      File.write(File.join(lib_dir, 'helper.rb'), 'HELPER = 1')
      File.write(File.join(tmpdir, 'Gemfile'), '')

      graph = @collector.call(File.join(tmpdir, 'entry.rb'))
      helper_path = File.join(lib_dir, 'helper.rb')
      assert graph[helper_path], "require with ./ path should resolve"
    end
  end

  def test_rbs_files_collected_when_sig_directory_exists
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), 'X = 1')
      File.write(File.join(tmpdir, 'Gemfile'), '')
      sig_dir = File.join(tmpdir, 'sig')
      Dir.mkdir(sig_dir)
      File.write(File.join(sig_dir, 'types.rbs'), 'class X end')

      graph = @collector.call(File.join(tmpdir, 'entry.rb'))
      rbs_path = File.join(sig_dir, 'types.rbs')
      assert_equal({ rbs_path => 'class X end' }, graph.rbs_files)
    end
  end

  def test_rbs_files_collected_from_rbs_stdlib_for_gems
    # When gem_names are provided, RBS stdlib definitions should be collected
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), 'require "json"')
      File.write(File.join(tmpdir, 'Gemfile'), '')

      graph = @collector.call(File.join(tmpdir, 'entry.rb'), gem_names: ['json'])
      rbs_files = graph.rbs_files
      json_rbs = rbs_files.keys.select { |path| path.include?('json') }
      refute_empty json_rbs, "RBS stdlib definitions for json should be collected"
    end
  end

  def test_rbs_files_empty_when_no_sig_directory
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'entry.rb'), 'X = 1')
      File.write(File.join(tmpdir, 'Gemfile'), '')

      graph = @collector.call(File.join(tmpdir, 'entry.rb'))
      assert_equal({}, graph.rbs_files)
    end
  end

  def test_require_inside_if_node_is_collected
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'helper.rb'), 'HELPER = 1')
      File.write(File.join(tmpdir, 'entry.rb'), <<~RUBY)
        if true
          require_relative 'helper'
        end
      RUBY
      File.write(File.join(tmpdir, 'Gemfile'), '')

      graph = @collector.call(File.join(tmpdir, 'entry.rb'))
      helper_path = File.join(tmpdir, 'helper.rb')
      assert graph[helper_path], "require inside if-node should be collected"
    end
  end

  def test_require_inside_begin_node_is_collected
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, 'helper.rb'), 'HELPER = 1')
      File.write(File.join(tmpdir, 'entry.rb'), <<~RUBY)
        begin
          require_relative 'helper'
        end
      RUBY
      File.write(File.join(tmpdir, 'Gemfile'), '')

      graph = @collector.call(File.join(tmpdir, 'entry.rb'))
      helper_path = File.join(tmpdir, 'helper.rb')
      assert graph[helper_path], "require inside begin-node should be collected"
    end
  end

  def test_single_file_no_dependencies
    entry_path = File.join(@fixtures_dir, 'independent_a.rb')
    graph = @collector.call(entry_path)

    entry = graph[entry_path]
    assert entry, "single file should be collected"
    assert_equal [], entry.dependencies
    assert_equal [], entry.in_class_dependencies
  end

  def test_explicit_project_root_enables_bare_require_resolution
    Dir.mktmpdir do |tmpdir|
      lib_dir = File.join(tmpdir, 'lib')
      Dir.mkdir(lib_dir)
      File.write(File.join(lib_dir, 'helper.rb'), 'HELPER = 1')
      File.write(File.join(lib_dir, 'entry.rb'), 'require "helper"')

      $LOAD_PATH.unshift(lib_dir)
      begin
        # Without project_root: find_project_root returns nil (no Gemfile/.git)
        # so bare requires are treated as stdlib
        graph_without = @collector.call(File.join(lib_dir, 'entry.rb'))
        entry_without = graph_without[File.join(lib_dir, 'entry.rb')]
        stdlib_nodes = entry_without.require_nodes.select { |n| n[:type] == :require_stdlib }
        assert_equal 1, stdlib_nodes.size, "Without project_root, bare require should be stdlib"

        # With explicit project_root, bare requires under that root should be resolved
        collector2 = Ryac::Pipeline::FileCollector.new
        graph_with = collector2.call(File.join(lib_dir, 'entry.rb'), project_root: tmpdir)
        helper_path = File.join(lib_dir, 'helper.rb')
        assert graph_with[helper_path], "With project_root, bare require should be resolved"
      ensure
        $LOAD_PATH.delete(lib_dir)
      end
    end
  end

  def test_multiple_project_roots_resolve_bare_requires
    Dir.mktmpdir do |tmpdir1|
      Dir.mktmpdir do |tmpdir2|
        lib1 = File.join(tmpdir1, 'lib')
        lib2 = File.join(tmpdir2, 'lib')
        Dir.mkdir(lib1)
        Dir.mkdir(lib2)

        File.write(File.join(lib1, 'entry.rb'), 'require "helper2"')
        File.write(File.join(lib2, 'helper2.rb'), 'HELPER2 = 2')

        $LOAD_PATH.unshift(lib1)
        $LOAD_PATH.unshift(lib2)
        begin
          # With multiple project_roots, bare requires under any root should resolve
          collector = Ryac::Pipeline::FileCollector.new
          graph = collector.call(
            File.join(lib1, 'entry.rb'),
            project_root: [tmpdir1, tmpdir2]
          )
          helper2_path = File.join(lib2, 'helper2.rb')
          assert graph[helper2_path], "Bare require under second project_root should be resolved"
        ensure
          $LOAD_PATH.delete(lib1)
          $LOAD_PATH.delete(lib2)
        end
      end
    end
  end
end
