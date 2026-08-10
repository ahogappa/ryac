# frozen_string_literal: true

module RubyMinify
  module Pipeline
    # `attr_reader :a` → `attr :a` (the same method, four bytes shorter) and
    # single-name attr_accessor → the two-argument attr form, for declarations
    # type analysis recognized as meta calls. This stage owns the attr rewrite
    # at every level: with rename_attrs the declared symbols are additionally
    # mapped through the analysis' attr rename map, keeping declarations in
    # sync with call sites the method renamer renames.
    class AttrDeclShorten
      include RenamePatcher

      def self.collect_patches_from(prism_ast, patches, analysis, kwargs = nil)
        new.collect(prism_ast, patches, analysis, rename_attrs: kwargs&.dig(:rename_attrs))
      end

      def self.postprocess(result, _analysis, aliases_str, preamble_str)
        [result, aliases_str, preamble_str]
      end

      def collect(node, patches, analysis, rename_attrs: false)
        attr_rename_map = analysis.attr_rename_map if rename_attrs
        walk_prism(node) do |subnode|
          next unless subnode.is_a?(Prism::CallNode)

          key = prism_location_key(subnode)
          meta = analysis.meta_node_map[key]
          next unless meta

          args = meta[:args] || []
          next unless args.any?

          names = args.map { |sym| attr_rename_map&.dig(key, sym) || sym.to_s }
          replacement = render_attr_declaration(meta[:type], names)
          next unless replacement && replacement != subnode.slice

          loc = subnode.location
          patches << { start: loc.start_offset, end: loc.end_offset, replacement: replacement }
        end
      end

      private

      # The compact spelling of an attr declaration: attr_reader collapses to
      # attr, a single-name attr_accessor takes the two-argument attr form, a
      # multi-name accessor has no shorter spelling.
      def render_attr_declaration(type, names)
        case type
        when :attr_reader
          "attr #{names.map { |n| ":#{n}" }.join(',')}"
        when :attr_accessor
          if names.size == 1
            "attr :#{names[0]},!!1"
          else
            "attr_accessor #{names.map { |n| ":#{n}" }.join(',')}"
          end
        end
      end
    end
  end
end
