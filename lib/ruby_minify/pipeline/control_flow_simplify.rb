# frozen_string_literal: true

require 'set'

module RubyMinify
  module Pipeline
    class ControlFlowSimplify
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

      # statement_position: the node is a direct child of a statements list.
      # A modifier rewrite is only sound there — in value position the
      # modifier captures the surrounding expression: `x = if c; v; end`
      # assigns nil when c is false, but `x = v if c` skips the assignment,
      # leaving x's previous value. (The compactor produces exactly that
      # shape from `x = c ? v : nil`.)
      def walk(node, source, patches, statement_position = false)
        case node
        when Prism::IfNode
          if node.end_keyword_loc && source.byteslice(node.if_keyword_loc.start_offset, 2) == 'if'
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
        when Prism::WhileNode
          if node.closing_loc
            if (replacement = try_while(node, source, statement_position))
              patches << mk(node, replacement)
              return
            end
          end
        when Prism::UntilNode
          if node.closing_loc
            if (replacement = try_until(node, source, statement_position))
              patches << mk(node, replacement)
              return
            end
          end
        end
        child_position = node.is_a?(Prism::StatementsNode)
        node.compact_child_nodes.each { |child| walk(child, source, patches, child_position) }
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

      def try_while(node, source, statement_position)
        return nil unless statement_position
        stmts = node.statements
        return nil unless stmts && AstUtils.single_statement_body?(stmts)
        body = src(source, stmts)
        return nil if body.include?(';')
        return nil if in_collection_context?(node, source)
        cond = src(source, node.predicate)
        "#{body} while #{cond}"
      end

      def too_complex_for_ternary?(text)
        text && (text.include?(';') ||
          text.match?(/\A(?:return|break|next|yield) /))
      end

      def try_until(node, source, statement_position)
        return nil unless statement_position
        stmts = node.statements
        return nil unless stmts && AstUtils.single_statement_body?(stmts)
        body = src(source, stmts)
        return nil if body.include?(';')
        return nil if in_collection_context?(node, source)
        cond = src(source, node.predicate)
        "#{body} until #{cond}"
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

      def collect_assigned_vars(node)
        vars = Set.new
        traverse(node) do |n|
          vars << n.name if n.is_a?(Prism::LocalVariableWriteNode)
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
