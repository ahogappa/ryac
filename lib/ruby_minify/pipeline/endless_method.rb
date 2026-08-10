# frozen_string_literal: true

module RubyMinify
  module Pipeline
    class EndlessMethod
      include SourcePatcher

      def call(input)
        source = input
        loop do
          ast = Prism.parse(source).value
          patches = []
          walk(ast, source, patches)
          break if patches.empty?
          new_source = apply_patches(source, patches)
          break if new_source == source
          source = new_source
        end
        source
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
          # Pattern matches need the parens too: `def f =expr in pat` parses
          # as `(def f =expr) in pat` — the match rebinds to the def itself.
          if keyword_logical?(stmt, source) || AstUtils.modifier_control_flow?(stmt) ||
             stmt.is_a?(Prism::MatchPredicateNode) || stmt.is_a?(Prism::MatchRequiredNode)
            body = "(#{body})"
          end
        end

        header_end = body_node.location.start_offset
        header = source.byteslice(node.location.start_offset, header_end - node.location.start_offset).chomp(';')

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
