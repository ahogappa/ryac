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

      # byteslice is typed String? but node offsets always lie inside the
      # source the node was parsed from, so the result is never nil.
      def src(source, node) # steep:ignore MethodBodyTypeMismatch
        source.byteslice(node.location.start_offset, node.location.length)
      end
    end
  end
end
