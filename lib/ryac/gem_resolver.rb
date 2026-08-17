# frozen_string_literal: true

module Ryac
  class GemResolver
    GemResolution = Data.define(:entry_path, :project_root, :require_paths)

    # The one spelling of "minify these installed gems": folds each gem's
    # resolution into the Minifier#call keyword arguments, so the CLI and
    # anything replicating it assemble the same invocation.
    def self.minifier_args(gem_names)
      resolver = new
      resolutions = gem_names.map { |name| resolver.call(name) }
      entry = resolutions.map(&:entry_path)
      entry = entry[0] if entry.size == 1
      {
        entry: entry,
        project_root: resolutions.map(&:project_root),
        gem_require_paths: resolutions.flat_map(&:require_paths),
      }
    end

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
