# frozen_string_literal: true

module Ryac
  module Pipeline
    # Same value, shorter spelling: symbol and string array literals collapse
    # to their percent forms when that is strictly smaller, and the English
    # spellings of Ruby's special globals collapse to their punctuation
    # forms — the same storage cell under either name. The pairing lives in
    # GvarRenameMapping::PERL_SPELLINGS, which also shields both spellings
    # from the gvar renamer.
    class SpellingShorten < Stage
      # Words a percent literal can carry verbatim: nothing that needs
      # escaping and nothing that could close or balance the delimiter.
      SAFE_WORD = %r{\A[A-Za-z0-9_/.:=!?-]+\z}

      def collect(ctx, patches)
        AstUtils.each_node(ctx.ast) do |node|
          case node
          when Prism::ArrayNode
            try_percent_array(node, patches)
          when Prism::GlobalVariableReadNode, Prism::GlobalVariableWriteNode
            short = GvarRenameMapping::PERL_SPELLINGS[node.name]
            if short
              loc = node.is_a?(Prism::GlobalVariableWriteNode) ? node.name_loc : node.location
              patches << { start: loc.start_offset, end: loc.end_offset, replacement: short }
            end
          end
        end
      end

      private

      def try_percent_array(node, patches)
        return unless node.opening == '['

        elements = node.elements
        return if elements.empty?

        sigil = if elements.all? { |e| plain?(e, Prism::SymbolNode) }
                  '%i'
                elsif elements.all? { |e| plain?(e, Prism::StringNode) }
                  '%w'
                end
        return unless sigil

        # Both node types carry their text as unescaped; SAFE_WORD already
        # guaranteed the text survives a percent literal verbatim.
        words = elements.map { |e| e.unescaped } # steep:ignore NoMethod
        new_size = 4 + words.sum(&:bytesize) + words.size - 1
        return unless new_size < node.location.length

        patches << mk(node, "#{sigil}[#{words.join(' ')}]")
      end

      def plain?(node, klass)
        node.is_a?(klass) && SAFE_WORD.match?(node.unescaped) # steep:ignore NoMethod
      end
    end
  end
end
