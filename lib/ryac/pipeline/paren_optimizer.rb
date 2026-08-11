# frozen_string_literal: true

module Ryac
  module Pipeline
    # Removes unnecessary parentheses from method calls at statement level.
    # Operates as a source patcher: Prism.parse → walk AST → collect patches → apply.
    # Only removes parens; never adds them.
    class ParenOptimizer
      def call(input_string, analysis: nil)
        ast = Prism.parse(input_string).value
        patches = []
        walk(ast, input_string, patches, statement_level: true)
        apply_patches(input_string, patches)
      end

      private

      def walk(node, source, patches, statement_level:)
        case node
        when Prism::ProgramNode
          walk(node.statements, source, patches, statement_level: true)

        when Prism::StatementsNode
          node.body.each { |child| walk(child, source, patches, statement_level: statement_level) }

        when Prism::CallNode
          try_remove_call_parens(node, source, patches) if statement_level
          walk_call_children(node, source, patches)

        when Prism::YieldNode
          try_remove_yield_parens(node, patches) if statement_level
          node.arguments&.arguments&.each { |arg| walk(arg, source, patches, statement_level: false) }

        when Prism::IfNode
          walk_if(node, source, patches)

        when Prism::UnlessNode
          walk(node.predicate, source, patches, statement_level: false)
          walk(node.statements, source, patches, statement_level: true) if node.statements
          walk(node.else_clause, source, patches, statement_level: true) if node.else_clause

        when Prism::ElseNode
          walk(node.statements, source, patches, statement_level: statement_level) if node.statements

        when Prism::WhileNode, Prism::UntilNode
          walk(node.predicate, source, patches, statement_level: false)
          walk(node.statements, source, patches, statement_level: true) if node.statements

        when Prism::ForNode
          walk(node.collection, source, patches, statement_level: false)
          walk(node.statements, source, patches, statement_level: true) if node.statements

        when Prism::DefNode
          walk(node.body, source, patches, statement_level: true) if node.body

        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          walk(node.body, source, patches, statement_level: true) if node.body

        when Prism::BeginNode
          walk(node.statements, source, patches, statement_level: true) if node.statements
          walk(node.rescue_clause, source, patches, statement_level: true) if node.rescue_clause
          walk(node.else_clause, source, patches, statement_level: true) if node.else_clause
          walk(node.ensure_clause, source, patches, statement_level: true) if node.ensure_clause

        when Prism::RescueNode
          walk(node.statements, source, patches, statement_level: true) if node.statements
          walk(node.subsequent, source, patches, statement_level: true) if node.subsequent

        when Prism::EnsureNode
          walk(node.statements, source, patches, statement_level: true) if node.statements

        when Prism::CaseNode
          walk(node.predicate, source, patches, statement_level: false) if node.predicate
          node.conditions.each { |cond| walk(cond, source, patches, statement_level: true) }
          walk(node.else_clause, source, patches, statement_level: true) if node.else_clause

        when Prism::WhenNode
          node.conditions.each { |c| walk(c, source, patches, statement_level: false) }
          walk(node.statements, source, patches, statement_level: true) if node.statements

        when Prism::CaseMatchNode
          walk(node.predicate, source, patches, statement_level: false) if node.predicate
          node.conditions.each { |cond| walk(cond, source, patches, statement_level: true) }
          walk(node.else_clause, source, patches, statement_level: true) if node.else_clause

        when Prism::InNode
          walk(node.statements, source, patches, statement_level: true) if node.statements

        when Prism::BlockNode, Prism::LambdaNode
          walk(node.body, source, patches, statement_level: true) if node.body

        when Prism::ParenthesesNode
          walk(node.body, source, patches, statement_level: statement_level) if node.body

        when Prism::LocalVariableWriteNode
          walk(node.value, source, patches, statement_level: statement_level)

        when Prism::PostExecutionNode
          walk(node.statements, source, patches, statement_level: true) if node.statements

        else
          node.compact_child_nodes.each { |child| walk(child, source, patches, statement_level: false) }
        end
      end

      def walk_if(node, source, patches)
        walk(node.predicate, source, patches, statement_level: false)

        if node.if_keyword_loc
          # Block-if or modifier-if: body is at statement level
          walk(node.statements, source, patches, statement_level: true) if node.statements
          walk(node.subsequent, source, patches, statement_level: true) if node.subsequent
        else
          # Ternary (no if_keyword_loc): arms are NOT at statement level
          walk(node.statements, source, patches, statement_level: false) if node.statements
          walk(node.subsequent, source, patches, statement_level: false) if node.subsequent
        end
      end

      def walk_call_children(node, source, patches)
        walk(node.receiver, source, patches, statement_level: false) if node.receiver
        node.arguments&.arguments&.each { |arg| walk(arg, source, patches, statement_level: false) }
        if node.block
          if node.block.is_a?(Prism::BlockNode)
            walk(node.block, source, patches, statement_level: true)
          else
            walk(node.block, source, patches, statement_level: false)
          end
        end
      end

      def try_remove_call_parens(node, source, patches)
        return unless node.opening_loc
        return unless AstUtils.can_omit_parens?(node)

        # Don't remove parens from calls with keyword args in modifier context.
        # After hash shorthand (`a:` for `a:a`), `foo a: if cond` is ambiguous.
        raw_args = node.arguments&.arguments || []
        if raw_args.any? { |a| a.is_a?(Prism::KeywordHashNode) }
          after = source.byteslice(node.closing_loc.end_offset, 10)
          return if after&.match?(/\A (?:if|unless|while|until) /)
        end

        add_paren_removal_patches(node.opening_loc, node.closing_loc, patches)
      end

      def try_remove_yield_parens(node, patches)
        return unless node.lparen_loc
        args = node.arguments&.arguments || []
        return if args.empty?

        add_paren_removal_patches(node.lparen_loc, node.rparen_loc, patches)
      end

      def add_paren_removal_patches(open_loc, close_loc, patches)
        patches << { start: open_loc.start_offset, end: open_loc.end_offset, replacement: ' ' }
        patches << { start: close_loc.start_offset, end: close_loc.end_offset, replacement: '' }
      end

      def apply_patches(source, patches)
        result = source.b.dup
        patches.sort_by { |p| -p[:start] }.each do |patch|
          result[patch[:start]...patch[:end]] = patch[:replacement]
        end
        result.force_encoding(source.encoding)
      end
    end
  end
end
