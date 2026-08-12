# frozen_string_literal: true

module Ryac
  module Pipeline
    class CharShorten
      include SourcePatcher

      def call(input)
        ast = Prism.parse(input).value
        patches = [] #: Array[patch_entry]
        walk(ast, patches)
        apply_patches(input, patches)
      end

      private

      def walk(node, patches)
        if node.is_a?(Prism::StringNode) && node.opening_loc && node.content.match?(/\A[a-zA-Z0-9_]\z/)
          patches << mk(node, "?#{node.content}")
        end
        node.compact_child_nodes.each { |child| walk(child, patches) }
      end
    end
  end
end
