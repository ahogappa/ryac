# frozen_string_literal: true

module Ryac
  module Pipeline
    class CharShorten < Stage
      def collect(ctx, patches)
        walk(ctx.ast, patches)
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
