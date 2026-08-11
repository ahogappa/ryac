# frozen_string_literal: true

module Ryac
  class GemResolver
    GemResolution = Data.define(:entry_path, :project_root, :require_paths)

    def call(gem_name)
      spec = Gem::Specification.find_by_name(gem_name)
      entry_path = find_entry_file(spec, gem_name)
      raise Pipeline::GemNotFoundError.new(gem_name) unless entry_path

      GemResolution.new(
        entry_path: entry_path,
        project_root: spec.gem_dir,
        require_paths: spec.full_require_paths
      )
    rescue Gem::MissingSpecError
      raise Pipeline::GemNotFoundError.new(gem_name)
    end

    private

    def find_entry_file(spec, gem_name)
      candidates = [
        gem_name,                  # json
        gem_name.tr('-', '_'),     # concurrent-ruby -> concurrent_ruby
        gem_name.tr('-', '/'),     # unicode-display_width -> unicode/display_width
      ].uniq

      spec.full_require_paths.each do |dir|
        candidates.each do |name|
          path = File.join(dir, "#{name}.rb")
          return path if File.exist?(path)
        end
      end

      nil
    end
  end
end
