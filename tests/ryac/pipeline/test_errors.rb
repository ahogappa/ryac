# frozen_string_literal: true

require_relative '../../test_helper'

class TestPipelineErrors < Minitest::Test
  def test_file_not_found_error_simple
    err = Ryac::Pipeline::FileNotFoundError.new("/missing.rb")
    assert_equal "File not found: /missing.rb", err.message
    assert_equal "/missing.rb", err.path
    assert_nil err.required_from
    assert_nil err.line
  end

  def test_file_not_found_error_with_source
    err = Ryac::Pipeline::FileNotFoundError.new(
      "/missing.rb", required_from: "/main.rb", line: 5
    )
    assert_equal "File not found: /missing.rb (required from /main.rb:5)", err.message
    assert_equal "/main.rb", err.required_from
    assert_equal 5, err.line
  end

  def test_file_not_found_is_stage_error
    err = Ryac::Pipeline::FileNotFoundError.new("/x.rb")
    assert_kind_of Ryac::Pipeline::StageError, err
  end

  def test_dynamic_require_error
    err = Ryac::Pipeline::DynamicRequireError.new(
      "/foo.rb", line: 10, expression: 'require name'
    )
    assert_equal "Dynamic require at /foo.rb:10: require name", err.message
    assert_equal "/foo.rb", err.path
    assert_equal 10, err.line
    assert_equal "require name", err.expression
  end

  def test_circular_dependency_error
    cycle = ["/a.rb", "/b.rb", "/a.rb"]
    err = Ryac::Pipeline::CircularDependencyError.new(cycle)
    assert_equal "Circular dependency: a.rb → b.rb → a.rb", err.message
    assert_equal cycle, err.cycle
  end

  def test_no_files_error
    err = Ryac::Pipeline::NoFilesError.new
    assert_equal "No files provided. Please provide an entry point file.", err.message
  end

  def test_gem_not_found_error
    err = Ryac::Pipeline::GemNotFoundError.new("nonexistent_gem")
    assert_equal "Gem not found: nonexistent_gem", err.message
    assert_equal "nonexistent_gem", err.gem_name
  end

  def test_gem_not_found_is_stage_error
    err = Ryac::Pipeline::GemNotFoundError.new("foo")
    assert_kind_of Ryac::Pipeline::StageError, err
  end
end
