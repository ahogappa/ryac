# frozen_string_literal: true

module Ryac
  module Pipeline
    module SourcePatcher
      private

      def mk(node, replacement)
        { start: node.location.start_offset, end: node.location.end_offset, replacement: replacement }
      end

      # The one patch applier: every stage splices byte patches through
      # here. Patches must be disjoint — an overlap means two rewrites
      # fought over the same bytes, and applying either order silently
      # corrupts the output, so it raises with both patches named. The
      # end-position tie-break keeps same-start insertions deterministic.
      def apply_patches(source, patches)
        return source if patches.none?
        sorted = patches.sort_by { |p| [-p[:start], -p[:end]] }
        sorted.each_cons(2) do |after, before|
          # each_cons(2) yields only full pairs; the destructuring alone is
          # what makes the elements look nilable.
          # @type var after: { start: Integer, end: Integer, replacement: String }
          # @type var before: { start: Integer, end: Integer, replacement: String }
          if before[:end] > after[:start]
            raise MinifyError, "overlapping patches: #{before.inspect} / #{after.inspect}"
          end
        end
        result = source.b.dup
        sorted.each do |patch|
          result[patch[:start]...patch[:end]] = patch[:replacement].b
        end
        result.force_encoding(source.encoding)
      end

      # byteslice is typed String? but node offsets always lie inside the
      # source the node was parsed from, so the result is never nil.
      def src(source, node) # steep:ignore MethodBodyTypeMismatch
        source.byteslice(node.location.start_offset, node.location.length)
      end

      # The output of every pipeline permutation must at minimum be valid
      # Ruby. Prism also rejects duplicated parameter names, so a rename that
      # collides inside a signature is caught here, at the stage that
      # produced it.
      def verify_parses(text, label)
        return if text.empty?

        errors = Prism.parse(text).errors
        raise InvalidOutputError.new(label, errors) unless errors.empty?
      end
    end
  end
end
