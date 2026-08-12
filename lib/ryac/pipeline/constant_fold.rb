# frozen_string_literal: true

module Ryac
  module Pipeline
    class ConstantFold
      include SourcePatcher

      FOLDABLE_OPS = %i[+ - * / % ** << >> & | ^].freeze
      INTEGER_ONLY_OPS = %i[<< >> & | ^].freeze

      def call(input)
        ast = Prism.parse(input).value
        patches = [] #: Array[patch_entry]
        walk(ast, patches)
        apply_patches(input, patches)
      end

      private

      def walk(node, patches)
        if node.is_a?(Prism::CallNode)
          folded = try_constant_fold(node)
          if folded
            replacement = folded.to_s
            if replacement.bytesize < node.location.length
              patches << mk(node, replacement)
              return
            end
          end
        end
        node.compact_child_nodes.each { |child| walk(child, patches) }
      end

      def try_constant_fold(node)
        case node
        when Prism::IntegerNode then node.value
        when Prism::FloatNode then node.value
        when Prism::ParenthesesNode
          body = node.body
          if body.is_a?(Prism::StatementsNode) && body.body.size == 1
            try_constant_fold(body.body.first)
          end
        when Prism::CallNode
          if node.receiver && node.arguments.nil? && node.name == :-@
            inner = try_constant_fold(node.receiver)
            return nil unless inner.is_a?(Numeric)
            -inner
          else
            try_fold_binary_op(node)
          end
        end
      end

      def try_fold_binary_op(node)
        return nil unless node.receiver
        return nil unless node.arguments&.arguments&.size == 1
        return nil if node.block

        op = node.name
        return nil unless FOLDABLE_OPS.include?(op)

        lhs = try_constant_fold(node.receiver)
        return nil unless lhs.is_a?(Numeric)

        # arguments proved non-nil above; Steep cannot carry that through the
        # repeated method call.
        rhs = try_constant_fold(node.arguments.arguments.first) # steep:ignore NoMethod
        return nil unless rhs.is_a?(Numeric)

        return nil if INTEGER_ONLY_OPS.include?(op) && !(lhs.is_a?(Integer) && rhs.is_a?(Integer))
        return nil if (op == :/ || op == :%) && rhs == 0

        result = apply_op(lhs, op, rhs)
        return nil unless result.is_a?(Integer) || result.is_a?(Float)
        return nil if result.is_a?(Float) && (result.nan? || result.infinite?)

        result
      rescue StandardError
        nil
      end

      def apply_op(lhs, op, rhs)
        case op
        when :+ then lhs + rhs
        when :- then lhs - rhs
        when :* then lhs * rhs
        when :/ then lhs / rhs
        when :% then lhs % rhs
        when :** then lhs ** rhs
        when :<< then lhs << rhs
        when :>> then lhs >> rhs
        when :& then lhs & rhs
        when :| then lhs | rhs
        when :^ then lhs ^ rhs
        end
      end
    end
  end
end
