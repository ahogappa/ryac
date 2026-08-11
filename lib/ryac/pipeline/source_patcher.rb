# frozen_string_literal: true

module Ryac
  module Pipeline
    module SourcePatcher
      private

      def mk(node, replacement)
        { start: node.location.start_offset, end: node.location.end_offset, replacement: replacement }
      end

      def apply_patches(source, patches)
        return source if patches.empty?
        result = source.b.dup
        patches.sort_by { |p| -p[:start] }.each do |patch|
          result[patch[:start]...patch[:end]] = patch[:replacement].b
        end
        result.force_encoding(source.encoding)
      end

      def src(source, node)
        source.byteslice(node.location.start_offset, node.location.length)
      end
    end
  end
end
