# frozen_string_literal: true

module Ryac
  module Pipeline
    class BooleanShorten
      include SourcePatcher

      def call(input)
        ast = Prism.parse(input).value
        patches = [] #: Array[patch_entry]
        walk(ast, patches)
        apply_patches(input, patches)
      end

      private

      def walk(node, patches, inside_block_params: false)
        case node
        when Prism::BlockParametersNode
          node.compact_child_nodes.each { |child| walk(child, patches, inside_block_params: true) }
          return
        when Prism::TrueNode
          patches << mk(node, '!!1') unless inside_block_params
        when Prism::FalseNode
          patches << mk(node, '!1') unless inside_block_params
        end
        node.compact_child_nodes.each { |child| walk(child, patches, inside_block_params: inside_block_params) }
      end
    end
  end
end
