# frozen_string_literal: true

module RubyMinify
  module Pipeline
    # Level 2-4: `attr_reader :a` → `attr :a` (the same method, four bytes
    # shorter) and single-name attr_accessor → the two-argument attr form,
    # for declarations type analysis recognized as meta calls. Level 5 does
    # not run this step: its method renamer performs the same rewrite while
    # renaming the symbols.
    class AttrDeclShorten
      include RenamePatcher

      def self.collect_patches_from(prism_ast, patches, analysis, _kwargs = nil)
        new.collect(prism_ast, patches, analysis)
      end

      def self.postprocess(result, _analysis, aliases_str, preamble_str)
        [result, aliases_str, preamble_str]
      end

      def collect(node, patches, analysis)
        walk_prism(node) do |subnode|
          next unless subnode.is_a?(Prism::CallNode)

          meta = analysis.meta_node_map[prism_location_key(subnode)]
          next unless meta

          args = meta[:args] || []
          next unless args.any?

          replacement = render_attr_declaration(meta[:type], args)
          next unless replacement && replacement != subnode.slice

          loc = subnode.location
          patches << { start: loc.start_offset, end: loc.end_offset, replacement: replacement }
        end
      end
    end
  end
end
