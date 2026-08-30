# frozen_string_literal: true

module Ryac
  module Pipeline
    class EndlessMethod < Stage
      # A conversion can expose another convertible def (nested singles),
      # so this runs to a fixed point.
      def fixpoint? = true

      def collect(ctx, patches)
        walk(ctx.ast, ctx.source, patches)
      end

      private

      def walk(node, source, patches)
        if node.is_a?(Prism::DefNode) && node.end_keyword_loc
          if (replacement = try_def(node, source))
            patches << mk(node, replacement)
            return
          end
        end
        node.compact_child_nodes.each { |child| walk(child, source, patches) }
      end

      def try_def(node, source)
        body_node = node.body
        return nil unless body_node.is_a?(Prism::StatementsNode)
        return nil if AstUtils.setter_def_name?(node.name)

        stmts = body_node.body
        return nil if stmts.any? { |s| s.is_a?(Prism::MultiWriteNode) }

        body = src(source, body_node)

        if stmts.size > 1
          body = "(#{body})"
        elsif (stmt = stmts.first)
          if keyword_logical?(stmt, source) || AstUtils.modifier_control_flow?(stmt) ||
             AstUtils.match_rebind?(stmt)
            body = "(#{body})"
          end
        end

        header_end = body_node.location.start_offset
        # the def header range is always inside the source, so byteslice is non-nil
        header = source.byteslice(node.location.start_offset, header_end - node.location.start_offset).chomp(';') # steep:ignore NoMethod

        "#{header} =#{body}"
      end

      def keyword_logical?(node, source)
        return false unless node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)

        op = source.byteslice(node.operator_loc.start_offset, node.operator_loc.length)
        op == 'and' || op == 'or'
      end
    end
  end
end
