# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/ryac/pipeline/stage'
require_relative '../lib/ryac/pipeline/data_types'
require_relative '../lib/ryac/pipeline/errors'
require_relative '../lib/ryac/pipeline/file_collector'

class TestFileCollector < Minitest::Test
  def setup
    @collector = Ryac::Pipeline::FileCollector.new
    @fixtures_dir = File.expand_path('fixtures/multi_file', __dir__)
  end

  # T010: Basic file collection test
  def test_collects_entry_file
    entry_path = File.join(@fixtures_dir, 'entry.rb')
    graph = @collector.call(entry_path)

    assert_instance_of Ryac::Pipeline::DependencyGraph, graph
    refute graph.empty?
    assert graph[entry_path], "Entry file should be in graph"
  end

  def test_collects_direct_dependencies
    entry_path = File.join(@fixtures_dir, 'entry.rb')
    graph = @collector.call(entry_path)

    # Should collect dependency_a and dependency_b
    dep_a_path = File.join(@fixtures_dir, 'lib', 'dependency_a.rb')
    dep_b_path = File.join(@fixtures_dir, 'lib', 'dependency_b.rb')

    assert graph[dep_a_path], "dependency_a should be in graph"
    assert graph[dep_b_path], "dependency_b should be in graph"
  end

  def test_file_entry_has_content
    entry_path = File.join(@fixtures_dir, 'entry.rb')
    graph = @collector.call(entry_path)

    entry = graph[entry_path]
    assert entry.content.include?('MyApplication'), "Entry content should include MyApplication"
  end

  def test_file_entry_has_dependencies
    entry_path = File.join(@fixtures_dir, 'entry.rb')
    graph = @collector.call(entry_path)

    entry = graph[entry_path]
    dep_a_path = File.join(@fixtures_dir, 'lib', 'dependency_a.rb')
    dep_b_path = File.join(@fixtures_dir, 'lib', 'dependency_b.rb')

    assert_includes entry.dependencies, dep_a_path
    assert_includes entry.dependencies, dep_b_path
  end

  def test_raises_error_for_missing_file
    missing_path = File.join(@fixtures_dir, 'nonexistent.rb')

    assert_raises Ryac::Pipeline::FileNotFoundError do
      @collector.call(missing_path)
    end
  end

  def test_raises_error_for_nil_entry
    assert_raises Ryac::Pipeline::NoFilesError do
      @collector.call(nil)
    end
  end

  # T019: Recursive dependency discovery test
  def test_collects_nested_dependencies
    entry_path = File.join(@fixtures_dir, 'entry.rb')
    graph = @collector.call(entry_path)

    # Should collect nested dependency_c through dependency_a
    dep_c_path = File.join(@fixtures_dir, 'lib', 'nested', 'dependency_c.rb')
    assert graph[dep_c_path], "Nested dependency_c should be in graph"
  end

  # Multi-entry tests
  def test_collects_multiple_entry_files
    paths = [
      File.join(@fixtures_dir, 'independent_a.rb'),
      File.join(@fixtures_dir, 'independent_b.rb')
    ]
    graph = @collector.call(paths)

    paths.each do |path|
      assert graph[File.expand_path(path)], "#{File.basename(path)} should be in graph"
    end
    assert_equal 2, graph.size
  end

  def test_collects_dependencies_from_all_entries
    paths = [
      File.join(@fixtures_dir, 'entry.rb'),
      File.join(@fixtures_dir, 'independent_a.rb')
    ]
    graph = @collector.call(paths)

    # entry.rb brings dependency_a, dependency_b, dependency_c
    # independent_a.rb has no deps
    assert_equal 5, graph.size
  end

  def test_deduplicates_shared_dependencies
    paths = [
      File.join(@fixtures_dir, 'entry.rb'),
      File.join(@fixtures_dir, 'entry_sharing_dep.rb')
    ]
    graph = @collector.call(paths)

    # entry.rb: dependency_a, dependency_b, dependency_c (nested)
    # entry_sharing_dep.rb: dependency_b (already collected)
    # Total unique: entry.rb, entry_sharing_dep.rb, dep_a, dep_b, dep_c = 5
    assert_equal 5, graph.size
  end

  def test_raises_error_for_missing_entry_in_array
    paths = [
      File.join(@fixtures_dir, 'independent_a.rb'),
      File.join(@fixtures_dir, 'nonexistent.rb')
    ]

    assert_raises Ryac::Pipeline::FileNotFoundError do
      @collector.call(paths)
    end
  end

  def test_single_string_still_works
    entry_path = File.join(@fixtures_dir, 'independent_a.rb')
    graph = @collector.call(entry_path)

    assert_equal 1, graph.size
    assert graph[File.expand_path(entry_path)]
  end

  # T021: Autoload statement handling test
  def test_handles_autoload_statements
    # Create a temporary fixture with autoload
    autoload_fixture = File.join(@fixtures_dir, 'autoload_entry.rb')
    File.write(autoload_fixture, <<~RUBY)
      autoload :DependencyB, './lib/dependency_b'
      module AutoloadTest
      end
    RUBY

    begin
      graph = @collector.call(autoload_fixture)
      dep_b_path = File.join(@fixtures_dir, 'lib', 'dependency_b.rb')
      assert graph[dep_b_path], "Autoloaded file should be in graph"
    ensure
      File.delete(autoload_fixture) if File.exist?(autoload_fixture)
    end
  end

  # RBS file discovery tests
  def test_discovers_rbs_files_from_sig_directory
    Dir.mktmpdir do |tmpdir|
      # Create project structure with Gemfile and sig/
      File.write(File.join(tmpdir, "Gemfile"), "source 'https://rubygems.org'")
      File.write(File.join(tmpdir, "main.rb"), "puts 'hello'")
      sig_dir = File.join(tmpdir, "sig")
      Dir.mkdir(sig_dir)
      File.write(File.join(sig_dir, "main.rbs"), "class Foo\n  def bar: () -> String\nend")

      graph = @collector.call(File.join(tmpdir, "main.rb"))
      assert_equal 1, graph.rbs_files.size
      assert_includes graph.rbs_files.keys.first, "main.rbs"
      assert_includes graph.rbs_files.values.first, "class Foo"
    end
  end

  def test_discovers_nested_rbs_files
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, "Gemfile"), "source 'https://rubygems.org'")
      File.write(File.join(tmpdir, "main.rb"), "puts 'hello'")
      nested_dir = File.join(tmpdir, "sig", "nested")
      FileUtils.mkdir_p(nested_dir)
      File.write(File.join(nested_dir, "types.rbs"), "class Bar\nend")

      graph = @collector.call(File.join(tmpdir, "main.rb"))
      assert_equal 1, graph.rbs_files.size
      assert_includes graph.rbs_files.keys.first, "types.rbs"
    end
  end

  def test_no_rbs_files_when_no_sig_directory
    Dir.mktmpdir do |tmpdir|
      File.write(File.join(tmpdir, "Gemfile"), "source 'https://rubygems.org'")
      File.write(File.join(tmpdir, "main.rb"), "puts 'hello'")

      graph = @collector.call(File.join(tmpdir, "main.rb"))
      assert_empty graph.rbs_files
    end
  end
end
