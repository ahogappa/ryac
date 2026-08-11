# frozen_string_literal: true

require_relative '../test_helper'

class TestGemResolver < Minitest::Test
  def setup
    @resolver = Ryac::GemResolver.new
    skip "json gem not available" unless Gem::Specification.find_all_by_name("json").any?
  end

  def test_resolve_known_gem
    result = @resolver.call("json")
    assert_instance_of Ryac::GemResolver::GemResolution, result
    assert result.entry_path
    assert result.project_root
  end

  def test_entry_path_is_existing_rb_file
    result = @resolver.call("json")
    assert result.entry_path.end_with?(".rb")
    assert File.exist?(result.entry_path)
  end

  def test_project_root_is_gem_dir
    result = @resolver.call("json")
    spec = Gem::Specification.find_by_name("json")
    assert_equal spec.gem_dir, result.project_root
  end

  def test_entry_path_is_under_project_root
    result = @resolver.call("json")
    assert result.entry_path.start_with?(result.project_root)
  end

  # No installed gem reliably has the hyphen-name/underscore-entry shape, so
  # the fallback is tested against a synthetic require path directly.
  def test_hyphenated_gem_falls_back_to_underscore_entry
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'fake_hyphen.rb'), '')
      spec = Struct.new(:full_require_paths).new([dir])
      path = @resolver.send(:find_entry_file, spec, 'fake-hyphen')
      assert_equal File.join(dir, 'fake_hyphen.rb'), path
    end
  end

  def test_resolve_unknown_gem_raises
    assert_raises(Ryac::Pipeline::GemNotFoundError) do
      @resolver.call("nonexistent_gem_xyz_12345")
    end
  end

  def test_resolve_unknown_gem_error_has_gem_name
    err = assert_raises(Ryac::Pipeline::GemNotFoundError) do
      @resolver.call("nonexistent_gem_xyz_12345")
    end
    assert_equal "nonexistent_gem_xyz_12345", err.gem_name
  end
end
