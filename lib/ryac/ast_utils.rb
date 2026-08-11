# frozen_string_literal: true

module Ryac
  module AstUtils
    module_function

    # The plain-symbol arguments of a call, as symbols — how attr_*,
    # private_constant and friends name their subjects.
    def symbol_arguments(call_node)
      call_node.arguments&.arguments&.filter_map { |arg|
        arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode)
      } || []
    end

    def unwrap_statements(node)
      return node unless node
      node = node.body if node.is_a?(Prism::ParenthesesNode)
      if node.is_a?(Prism::StatementsNode) && node.body.size == 1
        node.body.first
      else
        node
      end
    end

    MIDDLE_METHODS = %i[+ - * / ** % ^ > < <= >= <=> == === != & | << >> =~ !~].freeze

    def middle_method?(method)
      MIDDLE_METHODS.include?(method)
    end

    def logical_op?(node)
      node.is_a?(Prism::OrNode) || node.is_a?(Prism::AndNode)
    end

    def has_block?(node)
      node.block != nil
    end

    def single_statement_body?(body)
      return false if body.nil?
      return body.body.size == 1 if body.is_a?(Prism::StatementsNode)
      true
    end

    def setter_def_name?(name)
      s = name.to_s
      s.end_with?('=') && !%w[== != <= >= ===].include?(s)
    end

    def simple_negatable?(node)
      inner = unwrap_statements(node)
      return false if logical_op?(inner)

      inner.is_a?(Prism::CallNode) ? !middle_method?(inner.name) : true
    end

    def first_arg_starts_with_brace?(arg)
      inner = unwrap_statements(arg)
      return true if inner.is_a?(Prism::HashNode)
      return first_arg_starts_with_brace?(inner.receiver) if inner.is_a?(Prism::CallNode) && inner.receiver

      false
    end

    # Does this node's string representation end with a character
    # that could form `name!` or `name?` if `!` or `?` is appended?
    # Used for spacing before `!~` operator and ternary `?`/`:`.
    # Recursively follows rightmost sub-expressions for compound nodes.
    def ends_with_name_char?(node)
      inner = unwrap_statements(node)
      case inner
      # Terminals: definitely safe (end with delimiter/sigil/literal)
      when Prism::ParenthesesNode,
           Prism::StringNode, Prism::InterpolatedStringNode,
           Prism::InterpolatedSymbolNode,
           Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode,
           Prism::ArrayNode, Prism::HashNode, Prism::LambdaNode,
           Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode,
           Prism::GlobalVariableReadNode,
           Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
           Prism::DefinedNode, Prism::RescueModifierNode
        false
      # Bare symbol :name ends with name char; quoted :"name" ends with delimiter
      when Prism::SymbolNode
        !inner.closing_loc
      # Compound: follow rightmost sub-expression
      when Prism::OrNode, Prism::AndNode
        ends_with_name_char?(inner.right)
      when Prism::RangeNode
        inner.right ? ends_with_name_char?(inner.right) : false
      when Prism::CallNode
        return false if inner.block
        if middle_method?(inner.name)
          # Binary op: a+b → ends with right operand
          arg = inner.arguments&.arguments&.first
          arg ? ends_with_name_char?(arg) : true
        elsif inner.name == :[]=
          # Index assignment: recv[k]=val → ends with value
          last_arg = inner.arguments&.arguments&.last
          last_arg ? ends_with_name_char?(last_arg) : false
        elsif inner.receiver && !inner.arguments && (inner.name == :! || inner.name == :~)
          # Unary prefix operators: !x, ~x → output ends with operand
          ends_with_name_char?(inner.receiver)
        elsif inner.opening_loc
          false # foo(args) → ends with )
        elsif inner.name.to_s.end_with?('?', '!')
          false
        else
          true # bare method: foo.bar → ends with ident char
        end
      when Prism::YieldNode, Prism::SuperNode
        inner.arguments.nil?
      # Assignment: var=value → ends with value
      when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
           Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode,
           Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        ends_with_name_char?(inner.value)
      when Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
           Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
           Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
           Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
           Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
        ends_with_name_char?(inner.value)
      else
        true # conservative: local var, const, nil, true, false, self, etc.
      end
    end

    # Does this node's output end with ? or ! method suffix?
    # Recursively follows rightmost sub-expressions.
    def ends_with_method_suffix?(node)
      inner = unwrap_statements(node)
      case inner
      when Prism::OrNode, Prism::AndNode
        ends_with_method_suffix?(inner.right)
      when Prism::CallNode
        return false if inner.block
        return false if inner.opening_loc && inner.name != :[]=
        if middle_method?(inner.name)
          arg = inner.arguments&.arguments&.first
          arg ? ends_with_method_suffix?(arg) : false
        elsif inner.name == :[]=
          last_arg = inner.arguments&.arguments&.last
          last_arg ? ends_with_method_suffix?(last_arg) : false
        elsif inner.receiver && !inner.arguments && (inner.name == :! || inner.name == :~)
          # Unary prefix operators (!x, ~x) — output ends with operand, not suffix
          ends_with_method_suffix?(inner.receiver)
        else
          inner.name.to_s.end_with?('?', '!')
        end
      when Prism::SymbolNode
        !inner.closing_loc && inner.value.to_s.end_with?('?', '!')
      when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
           Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode,
           Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
           Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
           Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
           Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
           Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
           Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
        ends_with_method_suffix?(inner.value)
      else
        false
      end
    end

    # Needs space before ternary `?`?
    # True when condition ends with: name char, `?`, `!`, or digit.
    def needs_ternary_q_space?(node)
      ends_with_name_char?(node) || ends_with_method_suffix?(node)
    end

    def modifier_control_flow?(node)
      modifier_conditional?(node) || modifier_loop?(node)
    end

    def modifier_conditional?(node)
      case node
      when Prism::IfNode then node.if_keyword_loc && !node.end_keyword_loc
      when Prism::UnlessNode then node.keyword_loc && !node.end_keyword_loc
      else false
      end
    end

    def modifier_loop?(node)
      case node
      when Prism::WhileNode, Prism::UntilNode then !node.closing_loc
      else false
      end
    end

    # Bytes before which a ternary does NOT need wrapping parens
    TERNARY_SAFE_PREV = [';'.ord, "\n".ord, "\r".ord, '('.ord, '['.ord, '{'.ord].freeze
    COMPARISON_PREV   = ['<'.ord, '>'.ord, '!'.ord, '='.ord].freeze
    PIPE_BREAK_BYTES  = [';'.ord, "\n".ord, '{'.ord].freeze

    def ternary_needs_parens?(node, source)
      start = node.location.start_offset
      return false if start == 0
      prev = source.getbyte(start - 1)
      return false if TERNARY_SAFE_PREV.include?(prev)
      if prev == '='.ord
        return false if start < 2
        prev2 = source.getbyte(start - 2)
        return COMPARISON_PREV.include?(prev2)
      end
      if prev == '|'.ord
        return true if start < 3
        return true if source.getbyte(start - 2) == '|'.ord
        pos = start - 2
        while pos >= 0
          byte = source.getbyte(pos)
          if byte == '|'.ord
            return !(pos > 0 && source.getbyte(pos - 1) == '{'.ord)
          end
          break if PIPE_BREAK_BYTES.include?(byte)
          pos -= 1
        end
        return true
      end
      true
    end

    def can_omit_parens?(node, method_name = nil)
      return false if has_block?(node)
      # `.()` proc-call sugar has no message; its parens ARE the call.
      return false if node.message_loc.nil?
      raw_args = node.arguments&.arguments || []
      positional_args = raw_args.reject { |a| a.is_a?(Prism::KeywordHashNode) }
      return false if positional_args.empty?
      return false if raw_args.any? { |a| a.is_a?(Prism::ForwardingArgumentsNode) }
      return false if node.name == :[] || node.name == :[]=
      name_to_check = method_name || node.name.to_s
      return false if name_to_check.end_with?('?')
      return false if first_arg_starts_with_brace?(positional_args.first)
      return false if first_arg_is_regex?(positional_args.first)
      return false if raw_args.any? { |a| contains_bare_block?(a) }

      true
    end

    def first_arg_is_regex?(arg)
      arg.is_a?(Prism::RegularExpressionNode) || arg.is_a?(Prism::InterpolatedRegularExpressionNode)
    end

    def contains_bare_block?(node)
      case node
      when Prism::CallNode
        return true if node.block.is_a?(Prism::BlockNode)
        return true if node.receiver && contains_bare_block?(node.receiver)
        return false if node.opening_loc
        node.arguments&.arguments&.any? { |a| contains_bare_block?(a) } || false
      when Prism::ParenthesesNode, Prism::ArrayNode, Prism::HashNode, Prism::LambdaNode
        false
      when Prism::KeywordHashNode
        node.elements.any? { |e| e.is_a?(Prism::AssocNode) && contains_bare_block?(e.value) }
      when Prism::SplatNode
        contains_bare_block?(node.expression)
      else
        false
      end
    end

    # Depth-first over every node. The shared primitive for analyses that
    # need the whole tree without caring about scope or nesting context.
    def self.each_node(node, &block)
      return unless node.is_a?(Prism::Node)
      yield node
      node.compact_child_nodes.each { |child| each_node(child, &block) }
    end

    # Expressions that rebind to the surrounding statement when their parens
    # are stripped: `def f =expr in pat` parses as `(def f =expr) in pat`.
    # Every "needs parens" list must include these.
    MATCH_REBIND_NODES = [Prism::MatchPredicateNode, Prism::MatchRequiredNode].freeze

    def self.match_rebind?(node)
      MATCH_REBIND_NODES.any? { |t| node.is_a?(t) }
    end

    # The shorthand-pun values of a hash-ish node: implicit assoc values that
    # are NOT plain local reads (`{ label: }` calling method label). The one
    # definition of "pun" shared by the keyword and method exclusion passes.
    def self.shorthand_pun_values(node)
      return [] unless node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)

      node.elements.filter_map do |el|
        next unless el.is_a?(Prism::AssocNode) && el.value.is_a?(Prism::ImplicitNode)

        inner = el.value.value
        inner unless inner.is_a?(Prism::LocalVariableReadNode)
      end
    end

    # The Prism node a TypeProf node was built from — the other half of the
    # seam between the two trees, and the only supported way across it.
    #
    # TypeProf keeps this private because an editor has no reason to ask; we
    # ask constantly, since Prism is where the syntax we rewrite actually
    # lives. Reaching for the ivar in one place at least means a change
    # upstream breaks here and nowhere else.
    def self.prism_node(node)
      node.instance_variable_get(:@raw_node)
    end

    # The single place the analysis and the patchers agree on what "the same
    # piece of source" is. Analysis walks TypeProf's tree, patching walks
    # Prism's, and every map between them is keyed by this.
    #
    # Byte offsets, because that is the coordinate system patches are applied
    # in — deriving a separate line/column space for the join only gave the two
    # sides a way to disagree.
    #
    # TypeProf models source it may not be able to point back at: its nodes
    # carry no `location`, and its own `code_range` raises when a node has no
    # `@raw_node`. That is reasonable for an editor, where such a node is never
    # shown, but a node we cannot locate is one we cannot rename. Every node
    # reaching here does carry its Prism node — measured over a full
    # self-hosting run, 10327 of 10330 keys come from `@raw_node` and the rest
    # are Prism nodes already — so this raises rather than inventing a key that
    # could never match.
    def self.location_key(node)
      loc = node.respond_to?(:location) ? node.location : prism_node(node)&.location

      unless loc.respond_to?(:start_offset)
        raise ArgumentError, "no source location behind #{node.class}"
      end

      [loc.start_offset, loc.end_offset]
    end
  end
end
