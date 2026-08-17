# frozen_string_literal: true

require 'set'

module Ryac
  module Pipeline
    class ControlFlowSimplify < Stage
      # A collapse can make the enclosing construct collapsible in turn,
      # so this runs to a fixed point.
      def fixpoint? = true

      def collect(ctx, patches)
        walk(ctx.ast, ctx.source, patches)
      end

      private

      # statement_position: the node is a direct child of a statements list.
      # A modifier rewrite is only sound there — in value position the
      # modifier captures the surrounding expression: `x = if c; v; end`
      # assigns nil when c is false, but `x = v if c` skips the assignment,
      # leaving x's previous value. (The compactor produces exactly that
      # shape from `x = c ? v : nil`.)
      def walk(node, source, patches, statement_position = false)
        case node
        when Prism::IfNode
          # an IfNode with an end keyword always has its if/elsif keyword location
          if node.end_keyword_loc && source.byteslice(node.if_keyword_loc.start_offset, 2) == 'if' # steep:ignore NoMethod
            if (replacement = try_if(node, source, statement_position))
              patches << mk(node, replacement)
              return
            end
          end
        when Prism::UnlessNode
          if node.end_keyword_loc
            if (replacement = try_unless(node, source, statement_position))
              patches << mk(node, replacement)
              return
            end
          end
        when Prism::WhileNode, Prism::UntilNode
          if node.closing_loc
            keyword = node.is_a?(Prism::WhileNode) ? 'while' : 'until'
            if (replacement = try_loop(node, source, statement_position, keyword))
              patches << mk(node, replacement)
              return
            end
          end
        when Prism::DefNode
          try_tail_return(node, patches)
        end
        child_position = node.is_a?(Prism::StatementsNode)
        node.compact_child_nodes.each { |child| walk(child, source, patches, child_position) }
      end

      # The value of a def is its last expression; a trailing `return expr`
      # only restates that. Splats and multi-value returns build a value the
      # bare expression list would not, so only the single-value form goes.
      def try_tail_return(node, patches)
        body = node.body
        tail = case body
               when Prism::StatementsNode then body.body[-1]
               when Prism::ReturnNode then body
               end
        return unless tail.is_a?(Prism::ReturnNode)

        args = tail.arguments&.arguments
        return unless args && args.size == 1
        return if args[0].is_a?(Prism::SplatNode)

        patches << mk(tail, args[0].slice)
      end

      def try_if(node, source, statement_position)
        cond = src(source, node.predicate)
        stmts = node.statements

        if node.subsequent.nil?
          return nil unless stmts && AstUtils.single_statement_body?(stmts)
          body = src(source, stmts)
          return nil if body.include?(';')
          return nil if condition_assigns_var_used_in_body?(node.predicate, stmts)
          if statement_position
            return nil if in_collection_context?(node, source)
            "#{body} if #{cond}"
          else
            # As a value, the bare modifier would capture the surrounding
            # expression; parenthesized it stays a self-contained nil-or-body.
            "(#{body} if #{cond})"
          end
        else
          then_body = stmts ? src(source, stmts) : nil
          else_result = else_text_for_ternary(node.subsequent, source)
          return nil if else_result.nil?

          return nil if too_complex_for_ternary?(then_body)

          then_node = stmts.body.first if stmts
          return nil if then_node.is_a?(Prism::MultiWriteNode)
          result = build_ternary(node.predicate, cond, then_node, then_body, else_result)
          result = "(#{result})" if AstUtils.ternary_needs_parens?(node, source) || if_end_followed_by_operator?(node, source)
          result
        end
      end

      def else_text_for_ternary(subsequent, source)
        case subsequent
        when Prism::ElseNode
          stmts = subsequent.statements
          text = stmts ? src(source, stmts) : nil
          return nil if too_complex_for_ternary?(text)
          else_node = stmts&.body&.first
          return nil if else_node.is_a?(Prism::MultiWriteNode)
          text = "(#{text})" if else_node && AstUtils.modifier_control_flow?(else_node)
          text
        when Prism::IfNode
          cond = src(source, subsequent.predicate)
          stmts = subsequent.statements
          then_body = stmts ? src(source, stmts) : nil
          return nil if too_complex_for_ternary?(then_body)

          else_result = else_text_for_ternary(subsequent.subsequent, source)
          return nil if else_result.nil?

          then_node = stmts.body.first if stmts
          build_ternary(subsequent.predicate, cond, then_node, then_body, else_result)
        end
      end

      def build_ternary(cond_node, cond, then_node, then_expr, else_expr)
        if then_node && AstUtils.modifier_control_flow?(then_node)
          then_expr = "(#{then_expr})"
          then_node = nil
        end

        # and/or keywords have lower precedence than ?: — must wrap in parens
        needs_parens = cond_node.is_a?(Prism::AndNode) || cond_node.is_a?(Prism::OrNode)
        cond = "(#{cond})" if needs_parens

        if !needs_parens && AstUtils.needs_ternary_q_space?(cond_node)
          q_pre = ' '
          q_post = ' '
        else
          q_pre = ''
          q_post = ''
        end

        if then_node && (AstUtils.ends_with_name_char?(then_node) || AstUtils.ends_with_method_suffix?(then_node))
          colon_pre = ' '
          colon_post = ' '
        elsif else_expr&.start_with?(':')
          colon_pre = ''
          colon_post = ' '
        else
          colon_pre = ''
          colon_post = ''
        end

        "#{cond}#{q_pre}?#{q_post}#{then_expr}#{colon_pre}:#{colon_post}#{else_expr}"
      end

      def try_unless(node, source, statement_position)
        stmts = node.statements
        body = stmts ? src(source, stmts) : nil
        cond = src(source, node.predicate)

        modifier_ok = statement_position && body && !body.include?(';') &&
                      !condition_assigns_var_used_in_body?(node.predicate, stmts) &&
                      !in_collection_context?(node, source)

        if AstUtils.simple_negatable?(node.predicate)
          neg_cond = "!#{cond}"
          if modifier_ok
            "#{body} if #{neg_cond}"
          else
            "if #{neg_cond};#{body || ''};end"
          end
        elsif modifier_ok
          "#{body} unless #{cond}"
        end
      end

      def try_loop(node, source, statement_position, keyword)
        return nil unless statement_position
        stmts = node.statements
        return nil unless stmts && AstUtils.single_statement_body?(stmts)
        body = src(source, stmts)
        return nil if body.include?(';')
        return nil if condition_assigns_var_used_in_body?(node.predicate, stmts)
        return nil if in_collection_context?(node, source)
        cond = src(source, node.predicate)
        "#{body} #{keyword} #{cond}"
      end

      def too_complex_for_ternary?(text)
        text && (text.include?(';') ||
          text.match?(/\A(?:return|break|next|yield) /))
      end

      # Modifier if/unless/while/until is invalid inside array, hash, or argument
      # contexts. Check if the byte before the node (skipping whitespace) is a
      # comma, open bracket, or open paren.
      COLLECTION_CONTEXT_BYTES = [','.ord, '['.ord, '('.ord].freeze

      def in_collection_context?(node, source)
        pos = node.location.start_offset - 1
        while pos >= 0
          byte = source.getbyte(pos)
          if byte == ' '.ord || byte == "\n".ord || byte == "\r".ord || byte == "\t".ord
            pos -= 1
          else
            return COLLECTION_CONTEXT_BYTES.include?(byte)
          end
        end
        false
      end

      def condition_assigns_var_used_in_body?(predicate, body)
        assigned = collect_assigned_vars(predicate)
        return false if assigned.empty?
        read = collect_read_vars(body)
        assigned.intersect?(read)
      end

      # Every node kind that binds a local: plain writes, compound writes
      # (||= &&= +=), and multi-assignment targets. In the modifier form the
      # body parses before the condition runs, so a local the condition
      # binds reads as a method call there — any of these kinds counts.
      LOCAL_BINDING_NODES = [
        Prism::LocalVariableWriteNode,
        Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode,
        Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableTargetNode
      ].freeze

      def collect_assigned_vars(node)
        vars = Set.new
        traverse(node) do |n|
          case n
          when *LOCAL_BINDING_NODES
            # @type var n: Prism::LocalVariableWriteNode | Prism::LocalVariableOrWriteNode | Prism::LocalVariableAndWriteNode | Prism::LocalVariableOperatorWriteNode | Prism::LocalVariableTargetNode
            vars << n.name
          end
        end
        vars
      end

      def collect_read_vars(node)
        vars = Set.new
        traverse(node) do |n|
          vars << n.name if n.is_a?(Prism::LocalVariableReadNode)
        end
        vars
      end

      def traverse(node, &block)
        return unless node
        yield node
        node.compact_child_nodes.each { |child| traverse(child, &block) }
      end

      # Check if `end` keyword is followed by an operator (e.g., `if...end*(expr)`)
      # In that case, ternary conversion needs parentheses.
      OPERATOR_START_BYTES = [
        '*'.ord, '/'.ord, '%'.ord, '+'.ord, '-'.ord, '&'.ord,
        '|'.ord, '^'.ord, '<'.ord, '>'.ord, '.'.ord, '['.ord
      ].freeze

      def if_end_followed_by_operator?(node, source)
        end_loc = node.end_keyword_loc
        return false unless end_loc
        after = end_loc.end_offset
        return false if after >= source.bytesize
        OPERATOR_START_BYTES.include?(source.getbyte(after))
      end
    end
  end
end
