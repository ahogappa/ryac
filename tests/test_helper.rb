# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/tests/'
  add_filter '/vendor/'
  track_files 'lib/**/*.rb'
end

require 'minitest/autorun'
require 'open3'
require 'tempfile'
require 'rbconfig'
require_relative '../lib/ryac'
require_relative 'support/stage_recipes'

module MinifyTestHelper
  def minify_code(code, _options = {}, rbs_files: {})
    minify_at_level(code, Ryac::Minifier::DEFAULT_LEVEL, rbs_files: rbs_files)
  end

  def minify_at_level(code, level, verify_output: true, rbs_files: {}, lazy_files: [])
    stages = level.is_a?(Symbol) ? Ryac::Minifier::STAGES.fetch(level) : STAGE_RECIPES.fetch(level)
    result = Ryac::Minifier.run_stages(code, stages, rbs_files: rbs_files, lazy_files: lazy_files)

    assert_output_preserved(code, result) if verify_output
    result
  end

  def assert_output_preserved(original, rename_result)
    parts = [rename_result.preamble, rename_result.code, rename_result.aliases].reject(&:empty?)
    runnable = parts.join(';')
    orig_out, orig_success = run_ruby_code(original)
    min_out, min_success = run_ruby_code(runnable)
    assert_equal orig_success, min_success,
      "Exit status mismatch (original=#{orig_success}, minified=#{min_success})\nMinified code:\n#{runnable}"
    assert_equal orig_out, min_out,
      "Output mismatch.\nMinified code:\n#{runnable}"
  end

  private

  def run_ruby_code(code)
    Tempfile.create(['minify_test', '.rb']) do |f|
      f.write(code)
      f.flush
      stdout, _stderr, status = Open3.capture3(RbConfig.ruby, f.path)
      [stdout, status.success?]
    end
  end
end

# Fake node for unit testing rename mapping classes.
# Simulates code_range for Ryac.location_key.
module FakeNodeSupport
  # Stands in for Prism::Location: AstUtils.location_key keys everything by
  # byte offsets, so a double only has to offer those.
  FakeLocation = Struct.new(:start_offset, :end_offset)

  FAKE_CREF_CACHE = {}

  FakeCref = Struct.new(keyword_init: true) do
    def outer = nil
  end

  FakeLenv = Struct.new(:cref_id) do
    def cref
      FakeNodeSupport::FAKE_CREF_CACHE[cref_id] ||= FakeNodeSupport::FakeCref.new
    end
  end

  FakeNode = Struct.new(:id, :cref_id, keyword_init: true) do
    def initialize(id, cref_id: nil)
      super(id: id, cref_id: cref_id)
    end

    def location = FakeNodeSupport::FakeLocation.new(id, id)

    def lenv
      return nil unless cref_id
      FakeNodeSupport::FakeLenv.new(cref_id)
    end
  end

  def fake_node(id, **kw) = FakeNode.new(id, **kw)
  def loc_key(id) = [id, id]

end
