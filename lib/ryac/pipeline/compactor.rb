# frozen_string_literal: true

module Ryac
  module Pipeline
    # Level 0: Compaction — full AST rebuild with no syntax optimizations.
    # Removes comments and whitespace, joins with ";". Preserves original paren form.
    # No renaming, no TypeProf needed. Self-contained — no shared mixins.
    class Compactor
      BINARY_OPERATORS = %i[== != < > <= >= + - * / % & | ^ << >> === =~ !~ <=>].freeze
      NON_ASSOCIATIVE_OPS = %i[== === != =~ !~ <=>].to_set.freeze

      OPERATOR_PRECEDENCE = {
        :"|" => 1, :'^' => 1, :'&' => 2,
        :'<=>' => 3, :== => 3, :=== => 3, :!= => 3, :=~ => 3, :'!~' => 3,
        :> => 4, :>= => 4, :< => 4, :<= => 4,
        :<< => 5, :>> => 5,
        :+ => 6, :- => 6,
        :* => 7, :/ => 7, :% => 7,
        :** => 8
      }.freeze

      COMPOUND_WRITE_NODES = [
        Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
        Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
        Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
        Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
        Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
        Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
        Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode,
        Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
      ].freeze

      def call(input_string)
        @prism_ast = Prism.parse(input_string).value
        @inside_singleton_class = false
        @standard_error_redefined = nil
        rebuild.join(";")
      end

      private

      # --- Dispatch ---

      def rebuild
        results = [] #: Array[String]
        @prism_ast.statements.body.each do |subnode|
          result = r(subnode)
          results << result unless result.empty?
          break if node_returns_bot?(subnode)
        end
        results
      end

      def r(node)
        case node
        when Prism::CallNode then r_call(node)
        when Prism::DefNode then r_def(node)
        when Prism::YieldNode then r_yield(node)
        when Prism::IfNode then r_if(node)
        when Prism::UnlessNode then r_unless(node)
        when Prism::WhileNode then r_while(node)
        when Prism::CaseNode then r_case(node)
        when Prism::ReturnNode then r_return(node)
        when Prism::ClassNode then r_class(node)
        when Prism::ModuleNode then r_module(node)
        when Prism::AndNode then r_and(node)
        when Prism::OrNode then r_or(node)
        when Prism::LocalVariableWriteNode then "#{node.name}=#{r(node.value)}"
        when Prism::InstanceVariableWriteNode, Prism::GlobalVariableWriteNode,
             Prism::ClassVariableWriteNode then "#{node.name}=#{r(node.value)}"
        when Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
             Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
             Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
             Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
             Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
             Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
             Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode,
             Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode
          r_compound_write(node)
        when Prism::ConstantPathNode
          node.parent ? "#{r(node.parent)}::#{node.name}" : "::#{node.name}"
        when Prism::ConstantWriteNode then "#{node.name}=#{r(node.value)}"
        when Prism::ConstantPathWriteNode then "#{r(node.target)}=#{r(node.value)}"
        when Prism::StringNode then r_string(node)
        when Prism::IntegerNode then node.value.to_s
        when Prism::FloatNode then node.value.to_s
        when Prism::ArrayNode then r_array(node)
        when Prism::RangeNode then r_range(node)
        when Prism::SymbolNode then r_symbol(node)
        when Prism::HashNode then r_hash(node)
        when Prism::InterpolatedStringNode then r_interp_string(node)
        when Prism::InterpolatedSymbolNode then r_interp_symbol(node)
        when Prism::InterpolatedRegularExpressionNode then r_interp_regexp(node)
        when Prism::RegularExpressionNode then r_regexp(node)
        when Prism::StatementsNode then r_stmt(node)
        when Prism::ParenthesesNode then r_parens(node)
        when Prism::SuperNode then r_super(node)
        when Prism::BeginNode then r_begin(node)
        when Prism::RescueModifierNode then "(#{r(node.expression)} rescue #{r(node.rescue_expression)})"
        when Prism::BreakNode then r_break(node)
        when Prism::NextNode then r_next(node)
        when Prism::SplatNode then node.expression ? "*#{r(node.expression)}" : '*'
        when Prism::UntilNode then r_until(node)
        when Prism::AliasMethodNode then "alias #{r_alias_name(node.new_name)} #{r_alias_name(node.old_name)}"
        when Prism::UndefNode then "undef #{node.names.map { |n| r_alias_name(n) }.join(',')}"
        when Prism::LambdaNode then r_lambda(node)
        when Prism::PostExecutionNode then "END{#{r_stmt(node.statements)}}"
        when Prism::MultiWriteNode then r_multi_write(node)
        when Prism::MatchWriteNode then r(node.call)
        when Prism::DefinedNode then r_defined(node)
        when Prism::ForNode then r_for(node)
        when Prism::MatchRequiredNode then "#{r(node.value)}=>#{r(node.pattern)}"
        when Prism::MatchPredicateNode then "#{r(node.value)} in #{r(node.pattern)}"
        when Prism::SingletonClassNode then r_singleton_class(node)
        when Prism::CaseMatchNode then r_case_match(node)
        when Prism::ArrayPatternNode then r_array_pattern(node)
        when Prism::HashPatternNode then r_hash_pattern(node)
        when Prism::FindPatternNode then r_find_pattern(node)
        when Prism::AlternationPatternNode then "#{r(node.left)} | #{r(node.right)}"
        when Prism::CapturePatternNode then "#{r(node.value)}=>#{r_multi_target(node.target)}"
        when Prism::PinnedVariableNode then "^#{r(node.variable)}"
        when Prism::PinnedExpressionNode then "^(#{r(node.expression)})"
        when Prism::ImplicitNode then r(node.value)
        when Prism::ShareableConstantNode then r(node.write)
        when Prism::CallTargetNode then "#{r(node.receiver)}.#{node.name.to_s.chomp('=')}"
        when Prism::KeywordHashNode then r_keyword_hash(node)
        when Prism::TrueNode, Prism::FalseNode, Prism::NilNode, Prism::SelfNode,
             Prism::RedoNode, Prism::RetryNode, Prism::ForwardingSuperNode,
             Prism::ItLocalVariableReadNode, Prism::NumberedReferenceReadNode,
             Prism::SourceEncodingNode, Prism::SourceFileNode, Prism::SourceLineNode,
             Prism::LocalVariableReadNode, Prism::LocalVariableTargetNode,
             Prism::InstanceVariableReadNode, Prism::GlobalVariableReadNode,
             Prism::ClassVariableReadNode, Prism::ConstantReadNode,
             Prism::RationalNode, Prism::ImaginaryNode, Prism::MatchLastLineNode,
             Prism::InterpolatedMatchLastLineNode, Prism::FlipFlopNode,
             Prism::BackReferenceReadNode, Prism::AliasGlobalVariableNode
          node.slice
        else
          raise Ryac::MinifyError, "Unknown node: #{node.class}"
        end
      end

      def r_stmt(nodes)
        return '' if nodes.nil?

        if nodes.is_a?(Prism::StatementsNode)
          stmts = nodes.body
          singleton_defs = stmts.select { |s| s.is_a?(Prism::DefNode) && s.receiver.is_a?(Prism::SelfNode) }
          if singleton_defs.size >= 4
            results = [] #: Array[String]
            @inside_singleton_class = true
            inner = singleton_defs.map { |n| r(n) }
            @inside_singleton_class = false
            inner.reject! { |s| s.nil? || s.empty? }
            results << "class<<self;#{inner.join(';')};end"
            stmts.each do |subnode|
              next if subnode.is_a?(Prism::DefNode) && subnode.receiver.is_a?(Prism::SelfNode)
              result = r(subnode)
              results << result unless result.nil? || result.empty?
              break if node_returns_bot?(subnode)
            end
            results.join(";")
          else
            results = [] #: Array[String]
            stmts.each do |subnode|
              result = r(subnode)
              results << result unless result.nil? || result.empty?
              break if node_returns_bot?(subnode)
            end
            results.join(";")
          end
        else
          result = r(nodes)
          result.nil? || result.empty? ? '' : result
        end
      end

      # --- Method calls ---

      def r_call(node)
        return r_binary_op(node) if AstUtils.middle_method?(node.name)
        # has_block? guarantees a BlockNode/BlockArgumentNode, so r_block_call
        # cannot actually return nil here.
        return r_block_call(node) if AstUtils.has_block?(node) # steep:ignore ReturnTypeMismatch
        return r_index_access(node) if node.name == :'[]'
        return r_index_assign(node) if node.name == :'[]='
        return r_unary(node, '!') if node.name == :'!'
        return r_unary(node, node.name == :'-@' ? '-' : '+') if node.name == :'-@' || node.name == :'+@'
        call_op = node.safe_navigation? ? '&.' : '.'
        # `x.call(args)` has proc-call sugar: `x.(args)` dispatches to the
        # exact same method on any receiver. Erasing the message this early
        # is sound only because :call sits in EXCLUDED_METHODS — no renamer
        # ever needs to find these sites by name.
        if node.name == :call && node.receiver
          raw_args = node.arguments&.arguments || []
          return "#{recv_with_op(node.receiver, call_op)}(#{raw_args.map { |a| r(a) }.join(',')})"
        end
        method_name = node.name
        if setter_call?(node)
          # setter_call? implies exactly one argument is present
          "#{recv_with_op(node.receiver, call_op)}#{method_name}#{r(node.arguments.arguments.first)}" # steep:ignore NoMethod
        else
          "#{recv_with_op(node.receiver, call_op)}#{method_name}#{build_call_args(node)}"
        end
      end

      def r_binary_op(node)
        recv_str, recv_wrapped = wrap_operand(node.receiver, node.name, :left)
        # binary operator calls always carry exactly one argument
        arg_str, = wrap_operand(node.arguments.arguments.first, node.name, :right) # steep:ignore NoMethod
        op = node.name
        sep = binary_op_separator(node.receiver, recv_wrapped, op)
        "#{recv_str}#{sep}#{op}#{arg_str}"
      end

      def r_block_call(node)
        method_name = node.name
        call_op = node.safe_navigation? ? '&.' : '.'
        block = node.block
        if block.is_a?(Prism::BlockNode)
          block_params = extract_block_params(block)
          uses_numbered = block_params.any? { |p| p.match?(/^_\d+$/) }
          block_params_str = if block_params.empty? || uses_numbered || block_uses_it?(block.body)
            ""
          else
            "|#{block_params.join(',')}|"
          end
          "#{recv_with_op(node.receiver, call_op)}#{method_name}#{build_call_args(node)}{#{block_params_str}#{r_stmt(block.body)}}"
        elsif block.is_a?(Prism::BlockArgumentNode)
          bp = block.expression ? "&#{r(block.expression)}" : "&"
          "#{recv_with_op(node.receiver, call_op)}#{method_name}#{build_call_args(node, bp)}"
        end
      end

      def r_index_access(node)
        raw_args = node.arguments&.arguments || []
        args_str = raw_args.map { |a| r(a) }.join(',')
        if node.safe_navigation?
          "#{r(node.receiver)}&.[](#{args_str})"
        else
          "#{r(node.receiver)}[#{args_str}]"
        end
      end

      def r_index_assign(node)
        raw_args = node.arguments&.arguments || []
        if node.safe_navigation?
          "#{r(node.receiver)}&.[]=(#{raw_args.map { |a| r(a) }.join(',')})"
        else
          keys = raw_args[0..-2].map { |a| r(a) }.join(',') # steep:ignore NoMethod
          "#{r(node.receiver)}[#{keys}]=#{r(raw_args.last)}"
        end
      end

      def r_unary(node, op)
        recv_str = r(node.receiver)
        inner = AstUtils.unwrap_statements(node.receiver)
        needs_wrap = binary_operator_call?(inner) || AstUtils.logical_op?(inner)
        needs_wrap ? "#{op}(#{recv_str})" : "#{op}#{recv_str}"
      end

      # --- Definitions ---

      def r_def(node)
        method_name = node.name
        receiver_prefix = if node.receiver
          if @inside_singleton_class && node.receiver.is_a?(Prism::SelfNode)
            ""
          else
            "#{r(node.receiver)}."
          end
        else
          ""
        end
        all_params = build_def_params(node.parameters)
        body_node = node.body
        if body_node.is_a?(Prism::StatementsNode) && body_node.body.size == 1 &&
            body_node.body.first.is_a?(Prism::ParenthesesNode)
          body_node = body_node.body.first.body # steep:ignore NoMethod
        end
        body = r_stmt(body_node)
        params_str = all_params.empty? ? "" : "(#{all_params.join(',')})"
        "def #{receiver_prefix}#{method_name}#{params_str}#{fmt_body(body)};end"
      end

      def r_lambda(node)
        params_str = build_lambda_params(node.parameters)
        body = r_stmt(node.body)
        "->#{params_str}{#{body}}"
      end

      # --- Control flow ---

      def r_yield(node)
        args = node.arguments&.arguments || []
        return 'yield' if args.empty?
        "yield(#{args.map { |a| r(a) }.join(',')})"
      end

      def r_if(node)
        then_body = r_stmt(node.statements)
        else_node = node.subsequent
        else_body = case else_node
        when nil then nil
        when Prism::IfNode then r(else_node)
        when Prism::ElseNode
          inner = else_node.statements ? AstUtils.unwrap_statements(else_node.statements) : nil
          (inner.nil? || inner.is_a?(Prism::NilNode)) ? nil : r_stmt(else_node.statements)
        end

        if else_body.nil?
          "if #{r(node.predicate)};#{then_body || ''};end"
        elsif else_node.is_a?(Prism::IfNode)
          build_if_chain(node)
        else
          "if #{r(node.predicate)};#{then_body || ''};else;#{else_body};end"
        end
      end

      def r_unless(node)
        then_body = r_stmt(node.statements)
        "unless #{r(node.predicate)};#{then_body || ''};end"
      end

      def r_while(node)
        cond = r(node.predicate)
        body = r_stmt(node.statements)
        if node.begin_modifier?
          "#{body} while #{cond}"
        else
          "while #{cond}#{fmt_body(body)};end"
        end
      end

      def r_until(node)
        cond = r(node.predicate)
        body = r_stmt(node.statements)
        if node.begin_modifier?
          "#{body} until #{cond}"
        else
          "until #{cond}#{fmt_body(body)};end"
        end
      end

      def r_case(node)
        predicate = node.predicate ? " #{r(node.predicate)}" : ''
        body = "case#{predicate};" + node.conditions.map { |wn|
          conditions = wn.conditions.map { |c| r(c) }.join(',')
          "when #{conditions}#{fmt_body(r_stmt(wn.statements))}"
        }.join(";")
        if node.else_clause
          eb = node.else_clause.statements ? r_stmt(node.else_clause.statements) : nil
          body += ";else#{fmt_body(eb)}"
        end
        body + ";end"
      end

      def r_case_match(node)
        body = "case #{r(node.predicate)};"
        body += node.conditions.map { |in_node|
          "in #{r_in_pattern(in_node.pattern)}#{fmt_body(r_stmt(in_node.statements))}"
        }.join(";")
        if node.else_clause
          body += ";else#{fmt_body(r_stmt(node.else_clause.statements))}"
        end
        body + ";end"
      end

      # `in PATTERN if GUARD` parses with the guard as an If/Unless node
      # wrapping the pattern — rendering that as a statement-if corrupts the
      # clause into `in if guard;pattern;end`. Guards cannot nest, so the
      # wrapped node is always a plain pattern.
      def r_in_pattern(pattern)
        case pattern
        when Prism::IfNode, Prism::UnlessNode
          keyword = pattern.is_a?(Prism::IfNode) ? 'if' : 'unless'
          # a guard's IfNode always wraps a non-empty statements body
          "#{r(pattern.statements.body[0])} #{keyword} #{r(pattern.predicate)}" # steep:ignore NoMethod
        else
          r(pattern)
        end
      end

      def r_for(node)
        idx = node.index
        target = idx.is_a?(Prism::LocalVariableTargetNode) ? idx.name.to_s : idx.slice
        "for #{target} in #{r(node.collection)}#{fmt_body(r_stmt(node.statements))};end"
      end

      # --- Return / Break / Next ---

      MODIFIER_KEYWORD_NODES = [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode].freeze

      def r_return(node) = r_jump('return', node.arguments)
      def r_break(node) = r_jump('break', node.arguments)

      # A plain symbol drops its colon (`alias a b`); anything else — an
      # interpolated symbol — must keep its own syntax.
      def r_alias_name(node) = node.is_a?(Prism::SymbolNode) ? node.value.to_s : r(node)
      def r_next(node) = r_jump('next', node.arguments)

      def r_jump(keyword, arguments)
        args = arguments&.arguments
        return keyword if args.nil? || args.empty?
        result = args.map { |a| r(a) }.join(',')
        first = args.first
        unwrapped = first.is_a?(Prism::ParenthesesNode) ? AstUtils.unwrap_statements(first) : first
        MODIFIER_KEYWORD_NODES.any? { |t| unwrapped.is_a?(t) } ? "#{keyword}(#{result})" : "#{keyword} #{result}"
      end

      # --- Compound assignments ---

      def r_compound_write(node)
        target = case node
        when Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode
          r(node.target)
        when Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
          call_target(node)
        when Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode
          idx_target(node)
        else
          node.name
        end
        # binary_operator exists exactly on the *Operator* variants selected here
        op = node.class.name.include?('Operator') ? node.binary_operator : (node.class.name.include?('Or') ? '||' : '&&') # steep:ignore NoMethod
        compound(target, op, node)
      end

      def compound(target, op, node) = "#{target}#{op}=#{r(node.value)}"

      def call_target(node)
        recv_str = r(node.receiver)
        base = node.read_name.to_s.delete_suffix('=')
        call_op = node.safe_navigation? ? '&.' : '.'
        "#{recv_str}#{call_op}#{base}"
      end

      def idx_target(node)
        keys = (node.arguments&.arguments || []).map { |a| r(a) }.join(',')
        "#{r(node.receiver)}[#{keys}]"
      end

      # --- Literals ---

      def r_symbol(node)
        sym = node.value.to_sym # steep:ignore NoMethod
        name = sym.to_s
        if name.match?(/\A[a-zA-Z_]\w*[?!=]?\z/) || BINARY_OPERATORS.include?(sym) || %i[[] []=].include?(sym)
          ":#{name}"
        elsif name.start_with?('$')
          ":#{name}"
        else
          ":\"#{name.gsub('"', '\\"')}\""
        end
      end

      def r_regexp(node)
        content = node.content
        content = escape_regexp_slash(content) unless node.opening == '/'
        flags = node.closing[1..]
        "/#{content}/#{flags}"
      end

      def escape_regexp_slash(content)
        result = +""
        i = 0
        while i < content.size
          if content[i] == '\\'
            result << content[i] # steep:ignore ArgumentTypeMismatch
            i += 1
            result << content[i] if i < content.size # steep:ignore ArgumentTypeMismatch
            i += 1
          elsif content[i] == '/'
            result << '\\/'
            i += 1
          else
            result << content[i] # steep:ignore ArgumentTypeMismatch
            i += 1
          end
        end
        result
      end

      # --- Collections ---

      def r_array(node)
        opening = node.opening
        if opening == "%i[" && node.elements.all? { |e| e.is_a?(Prism::SymbolNode) }
          # the all?(SymbolNode) / all?(StringNode) guards make &:value/&:content safe
          "%i[#{node.elements.map(&:value).join(' ')}]" # steep:ignore BlockTypeMismatch
        elsif opening == "%w[" && node.elements.all? { |e| e.is_a?(Prism::StringNode) }
          "%w[#{node.elements.map(&:content).join(' ')}]" # steep:ignore BlockTypeMismatch
        else
          "[#{node.elements.map { r(_1) }.join(',')}]"
        end
      end

      def r_range(node)
        op = node.exclude_end? ? '...' : '..'
        left = node.left ? r(node.left) : ''
        right = node.right ? r(node.right) : ''
        "(#{left}#{op}#{right})"
      end

      def r_hash(node)
        "{" + node.elements.map { |e|
          e.is_a?(Prism::AssocSplatNode) ? "**#{r(e.value)}" : r_assoc(e)
        }.join(',') + "}"
      end

      def r_keyword_hash(node)
        node.elements.map { |e|
          e.is_a?(Prism::AssocSplatNode) ? "**#{r(e.value)}" : r_assoc(e)
        }.join(',')
      end

      def r_assoc(element)
        key = element.key
        val = element.value
        val_str = r(val)
        if key.is_a?(Prism::SymbolNode) && key.value.to_s.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
          key_name = key.value.to_s
          return "#{key_name}:" if val.is_a?(Prism::ImplicitNode)
          sep = val_str.start_with?(':') ? ': ' : ':'
          "#{key_name}#{sep}#{val_str}"
        else
          key_str = r(key)
          separator = if key.is_a?(Prism::SymbolNode) && !key.value.to_s.match?(/[a-zA-Z0-9_]\z/)
            ' =>'
          else
            '=>'
          end
          "#{key_str}#{separator}#{val_str}"
        end
      end

      # --- Strings ---

      def r_string(node)
        if node.opening == '"' || node.opening.nil?
          "\"#{node.content}\""
        else
          node.unescaped.inspect
        end
      end

      # --- Interpolation ---

      def r_interp_string(node)
        needs_escape = node.opening != '"'
        "\"" + node.parts.map { |p| interp_part(p, escape_quotes: needs_escape) }.join + "\""
      end

      def r_interp_symbol(node)
        ":\"" + node.parts.map { |p| interp_part(p) }.join + "\""
      end

      def r_interp_regexp(node)
        needs_slash_escape = node.opening != '/'
        parts = node.parts.map { |p|
          if needs_slash_escape && p.is_a?(Prism::StringNode)
            escape_regexp_slash(p.content)
          else
            interp_part(p)
          end
        }
        "/" + parts.join + "/#{node.closing[1..]}"
      end

      def interp_part(part, escape_quotes: false)
        case part
        when Prism::StringNode
          if escape_quotes
            escape_for_dquote(part.unescaped)
          else
            part.content
          end
        when Prism::EmbeddedStatementsNode then "\#{#{r_stmt(part.statements)}}"
        when Prism::EmbeddedVariableNode then "\#{#{r(part.variable)}}"
        else "\#{#{r(part)}}"
        end
      end

      def escape_for_dquote(str)
        result = +""
        i = 0
        while i < str.size
          c = str[i]
          case c
          when '\\' then result << '\\\\'
          when '"' then result << '\\"'
          when "\n" then result << '\\n'
          when "\t" then result << '\\t'
          when "\r" then result << '\\r'
          when "\0" then result << '\\0'
          when '#'
            if i + 1 < str.size && '{@$'.include?(str[i + 1]) # steep:ignore ArgumentTypeMismatch
              result << '\\#'
            else
              result << '#'
            end
          else
            result << c # steep:ignore ArgumentTypeMismatch
          end
          i += 1
        end
        result
      end

      # --- Classes / Modules ---

      def r_class(node)
        class_name = node.constant_path.slice
        superclass_str = node.superclass ? "<#{r(node.superclass)}" : ''
        "class #{class_name}#{superclass_str}#{fmt_body(r_stmt(node.body))};end"
      end

      def r_module(node)
        "module #{node.constant_path.slice}#{fmt_body(r_stmt(node.body))};end"
      end

      def r_singleton_class(node)
        "class<<#{r(node.expression)}#{fmt_body(r_stmt(node.body))};end"
      end

      # --- Logic ---

      def r_and(node)
        e1 = r(node.left)
        e2 = r(node.right)
        if node.operator == 'and'
          e2 = "(#{e2})" if AstUtils.unwrap_statements(node.right).is_a?(Prism::OrNode)
          "#{e1} and #{e2}"
        else
          e1 = "(#{e1})" if AstUtils.unwrap_statements(node.left).is_a?(Prism::OrNode)
          e2 = "(#{e2})" if AstUtils.unwrap_statements(node.right).is_a?(Prism::OrNode)
          "#{e1}&&#{e2}"
        end
      end

      def r_or(node)
        e1 = r(node.left)
        e2 = r(node.right)
        if node.operator == 'or'
          e2 = "(#{e2})" if AstUtils.unwrap_statements(node.right).is_a?(Prism::AndNode)
          "#{e1} or #{e2}"
        else
          "#{e1}||#{e2}"
        end
      end

      # --- Error handling ---

      def r_begin(node)
        parts = ["begin#{fmt_body(r_stmt(node.statements))}"]
        rescue_node = node.rescue_clause
        while rescue_node
          rp = ';rescue'
          exceptions = rescue_node.exceptions || []
          # `rescue StandardError` is what a bare rescue already means —
          # unless the program redefines StandardError, when the bare form
          # would resolve differently.
          unless exceptions.empty? || (bare_standard_error?(exceptions) && !standard_error_redefined?)
            rp += " #{exceptions.map { |e| r(e) }.join(',')}"
          end
          if rescue_node.reference && rescue_var_used?(rescue_node)
            # the reference is a name-bearing target node in valid rescue clauses
            rp += "=>#{rescue_node.reference.name}" # steep:ignore NoMethod
          end
          parts << "#{rp}#{fmt_body(r_stmt(rescue_node.statements))}"
          rescue_node = rescue_node.subsequent
        end
        parts << ";else#{fmt_body(r_stmt(node.else_clause.statements))}" if node.else_clause
        parts << ";ensure#{fmt_body(r_stmt(node.ensure_clause.statements))}" if node.ensure_clause
        parts << ';end'
        parts.join
      end

      def bare_standard_error?(exceptions)
        exceptions.size == 1 &&
          exceptions[0].is_a?(Prism::ConstantReadNode) &&
          exceptions[0].name == :StandardError
      end

      # Lazy: only a literal `rescue StandardError` clause ever needs the
      # answer, so most programs never pay for the walk. Any definition-ish
      # node whose written name is StandardError counts — over-matching a
      # nested Foo::StandardError only forgoes a few bytes.
      def standard_error_redefined?
        # a non-nil memo is always one of the two bools
        return @standard_error_redefined unless @standard_error_redefined.nil? # steep:ignore ReturnTypeMismatch

        found = false
        AstUtils.each_node(@prism_ast) do |node|
          case node
          when Prism::ClassNode
            path = node.constant_path
            name = path.is_a?(Prism::ConstantReadNode) || path.is_a?(Prism::ConstantPathNode) ? path.name : nil
            found = true if name == :StandardError
          when Prism::ConstantWriteNode, Prism::ConstantTargetNode
            found = true if node.name == :StandardError
          when Prism::ConstantPathWriteNode
            found = true if node.target.name == :StandardError
          when Prism::ConstantPathTargetNode
            found = true if node.name == :StandardError
          end
        end
        @standard_error_redefined = found
      end

      # --- Other ---

      def r_super(node)
        args = node.arguments&.arguments&.map { |a| r(a) } || []
        args_str = args.join(',')
        args_str.empty? ? 'super()' : "super(#{args_str})"
      end

      def r_defined(node)
        "defined?(#{r(node.value)})"
      rescue
        "defined?(#{node.value.slice})"
      end

      # --- Multi-write ---

      def r_multi_write(node)
        targets = node.lefts.map { |t| r_multi_target(t) }
        if node.rest
          case node.rest
          when Prism::SplatNode
            targets << (node.rest.expression ? "*#{r_multi_target(node.rest.expression)}" : '*')
          when Prism::ImplicitRestNode
            targets << '*'
          end
        end
        targets.concat(node.rights.map { |t| r_multi_target(t) })
        value = node.value
        sep = targets.last&.end_with?('*') ? ' ' : ''
        if value.is_a?(Prism::ArrayNode) && (value.opening_loc.nil? || value.elements.size >= 2)
          elements = value.elements.map { |e| r(e) }
          "#{targets.join(',')}#{sep}=#{elements.join(',')}"
        else
          "#{targets.join(',')}#{sep}=#{r(value)}"
        end
      end

      def r_multi_target(target)
        case target
        when Prism::LocalVariableTargetNode, Prism::InstanceVariableTargetNode,
             Prism::ClassVariableTargetNode, Prism::GlobalVariableTargetNode
          target.name.to_s
        when Prism::ConstantTargetNode
          target.name.to_s
        when Prism::ConstantPathTargetNode
          target.parent ? "#{r(target.parent)}::#{target.name}" : "::#{target.name}"
        when Prism::MultiTargetNode
          parts = target.lefts.map { |t| r_multi_target(t) }
          if target.rest
            case target.rest
            when Prism::SplatNode
              parts << (target.rest.expression ? "*#{r_multi_target(target.rest.expression)}" : '*')
            when Prism::ImplicitRestNode
              parts << '*'
            end
          end
          parts.concat(target.rights.map { |t| r_multi_target(t) })
          parts.join(',')
        when Prism::IndexTargetNode
          args = target.arguments&.arguments || []
          "#{r(target.receiver)}[#{args.map { |a| r(a) }.join(',')}]"
        when Prism::SplatNode
          target.expression ? "*#{r_multi_target(target.expression)}" : '*'
        else
          r(target)
        end
      end

      # --- Pattern matching ---

      def r_array_pattern(node)
        parts = node.requireds.map { |n| r(n) }
        if node.rest
          parts << if node.rest.is_a?(Prism::SplatNode) && node.rest.expression
            "*#{r(node.rest.expression)}"
          else
            '*'
          end
        end
        parts.concat(node.posts.map { |p| r(p) })
        "[#{parts.join(',')}]"
      end

      def r_hash_pattern(node)
        # hash-pattern keys are always plain SymbolNodes
        parts = node.elements.map { |a| "#{a.key.value}: #{r(a.value)}" } # steep:ignore NoMethod
        if node.rest
          case node.rest
          when Prism::AssocSplatNode
            parts << (node.rest.value ? "**#{r(node.rest.value)}" : '**')
          when Prism::NoKeywordsParameterNode
            parts << '**nil'
          end
        end
        "{#{parts.join(',')}}"
      end

      def r_find_pattern(node)
        parts = [] #: Array[String]
        if node.left
          parts << if node.left.is_a?(Prism::SplatNode) && node.left.expression
            "*#{r(node.left.expression)}"
          else
            '*'
          end
        end
        parts.concat(node.requireds.map { |n| r(n) })
        if node.right
          parts << if node.right.is_a?(Prism::SplatNode) && node.right.expression
            "*#{r(node.right.expression)}"
          else
            '*'
          end
        end
        "[#{parts.join(',')}]"
      end

      # --- Helpers ---

      def build_call_args(node, block_pass = nil)
        raw_args = node.arguments&.arguments || []
        args = [] #: Array[String]
        raw_args.each do |arg|
          case arg
          when Prism::SplatNode
            args << (arg.expression ? "*#{r(arg.expression)}" : '*')
          when Prism::KeywordHashNode
            arg.elements.each do |el|
              args << (el.is_a?(Prism::AssocSplatNode) ? "**#{r(el.value)}" : r_assoc(el))
            end
          when Prism::ForwardingArgumentsNode
            args << '...'
          else
            args << r(arg)
          end
        end
        args << block_pass if block_pass
        return '' if args.empty?
        "(#{args.join(',')})"
      end

      def build_def_params(params)
        return [] unless params

        req = (params.requireds || []).map { |p|
          case p
          when Prism::RequiredParameterNode then p.name.to_s
          when Prism::MultiTargetNode then r_multi_target_param(p)
          else p.slice
          end
        }
        opt = (params.optionals || []).map { |p| "#{p.name}=#{r(p.value)}" }
        rest = if params.rest.is_a?(Prism::RestParameterNode)
          [params.rest.name ? "*#{params.rest.name}" : '*']
        else
          [] #: Array[String]
        end
        post = (params.posts || []).map { |p|
          p.is_a?(Prism::RequiredParameterNode) ? p.name.to_s : p.slice
        }
        req_kw = [] #: Array[String]
        opt_kw = [] #: Array[String]
        (params.keywords || []).each do |p|
          case p
          when Prism::RequiredKeywordParameterNode then req_kw << "#{p.name}:"
          when Prism::OptionalKeywordParameterNode
            val = r(p.value)
            sep = val.start_with?(':') ? ' ' : ''
            opt_kw << "#{p.name}:#{sep}#{val}"
          end
        end
        rest_kw = if params.keyword_rest.is_a?(Prism::KeywordRestParameterNode)
          [params.keyword_rest.name ? "**#{params.keyword_rest.name}" : '**']
        elsif params.keyword_rest.is_a?(Prism::NoKeywordsParameterNode)
          ['**nil']
        elsif params.keyword_rest.is_a?(Prism::ForwardingParameterNode)
          ['...']
        else
          [] #: Array[String]
        end
        block_param = if params.block.is_a?(Prism::BlockParameterNode)
          [params.block.name ? "&#{params.block.name}" : '&']
        else
          [] #: Array[String]
        end
        req + opt + rest + post + req_kw + opt_kw + rest_kw + block_param
      end

      def r_multi_target_param(target)
        parts = target.lefts.map { |t|
          case t
          when Prism::RequiredParameterNode then t.name.to_s
          when Prism::MultiTargetNode then r_multi_target_param(t)
          else t.slice
          end
        }
        if target.rest
          parts << (target.rest.is_a?(Prism::SplatNode) && target.rest.expression ? "*#{target.rest.expression.slice}" : '*')
        end
        parts.concat(target.rights.map { |t| t.respond_to?(:name) ? t.name.to_s : t.slice }) # steep:ignore NoMethod
        "(#{parts.join(',')})"
      end

      def build_lambda_params(block_params)
        return "" unless block_params.is_a?(Prism::BlockParametersNode)
        inner = block_params.parameters
        return "()" unless inner
        all = build_def_params(inner)
        all.empty? ? "" : "(#{all.join(',')})"
      end

      def extract_block_params(block)
        return [] unless block.parameters.is_a?(Prism::BlockParametersNode) && block.parameters.parameters
        build_def_params(block.parameters.parameters)
      end

      def recv_with_op(recv_node, call_op)
        return '' if recv_node.nil?
        recv_str = r(recv_node)
        inner = AstUtils.unwrap_statements(recv_node)
        # Unary calls must keep their parens under a chain: `(-vec).to_a`
        # stripped to `-vec.to_a` rebinds as `-(vec.to_a)` — String#-@ even
        # makes that run silently instead of failing.
        needs_wrap = binary_operator_call?(inner) || AstUtils.logical_op?(inner) ||
                     inner.is_a?(Prism::TrueNode) || inner.is_a?(Prism::FalseNode) ||
                     (inner.is_a?(Prism::CallNode) && %i[! -@ +@].include?(inner.name))
        needs_wrap ? "(#{recv_str})#{call_op}" : "#{recv_str}#{call_op}"
      end

      def wrap_operand(node, parent_op, side)
        return ['', true] if node.nil?
        str = r(node)
        inner = AstUtils.unwrap_statements(node)
        return ["(#{str})", true] if AstUtils.logical_op?(inner)
        # ** binds tighter than unary minus: `(-a)**b` must not become -a**b.
        if parent_op == :** && inner.is_a?(Prism::CallNode) && %i[-@ +@].include?(inner.name)
          return ["(#{str})", true]
        end
        if binary_operator_call?(inner)
          pp = OPERATOR_PRECEDENCE[parent_op]
          # binary_operator_call? has established inner is a CallNode
          cp = OPERATOR_PRECEDENCE[inner.name] # steep:ignore NoMethod
          if pp && cp
            return ["(#{str})", true] if cp < pp
            return ["(#{str})", true] if cp == pp && side == :right
            return ["(#{str})", true] if cp == pp && NON_ASSOCIATIVE_OPS.include?(parent_op)
          end
        end
        [str, false]
      end

      def binary_op_separator(recv_node, recv_wrapped, op)
        return '' if recv_wrapped
        inner = AstUtils.unwrap_statements(recv_node)
        if op == :'!~'
          AstUtils.ends_with_name_char?(inner) ? ' ' : ''
        elsif op.to_s.start_with?('=') && inner.is_a?(Prism::CallNode) && inner.name.to_s.end_with?('?', '!')
          ' '
        else
          ''
        end
      end

      def build_if_chain(node)
        parts = [] #: Array[String]
        current = node
        keyword = "if"
        loop do
          inner = current.statements ? AstUtils.unwrap_statements(current.statements) : nil
          then_body = (inner.nil? || inner.is_a?(Prism::NilNode)) ? nil : r_stmt(current.statements)
          parts << "#{keyword} #{r(current.predicate)}#{fmt_body(then_body)}"
          subsequent = current.subsequent
          if subsequent.is_a?(Prism::IfNode)
            current = subsequent
            keyword = "elsif"
          else
            if subsequent.is_a?(Prism::ElseNode)
              inner = subsequent.statements ? AstUtils.unwrap_statements(subsequent.statements) : nil
              unless inner.nil? || inner.is_a?(Prism::NilNode)
                eb = r_stmt(subsequent.statements)
                parts << "else#{fmt_body(eb)}" if eb && !eb.empty?
              end
            end
            break
          end
        end
        parts.join(";") + ";end"
      end

      ASSIGNMENT_NODES = [
        Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
        Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode,
        Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::MultiWriteNode,
        *COMPOUND_WRITE_NODES,
      ].freeze

      # Match nodes keep parens like assignments do: an endless def body of
      # `(value in pattern)` stripped bare rebinds the `in` to the def
      # statement itself and no longer parses.
      PARENS_KEPT_NODES = [*ASSIGNMENT_NODES, *AstUtils::MATCH_REBIND_NODES].freeze

      def r_parens(node)
        body = r_stmt(node.body)
        inner = AstUtils.unwrap_statements(node)
        if node.body.is_a?(Prism::StatementsNode) && node.body.body.size > 1
          "(#{body})"
        elsif PARENS_KEPT_NODES.any? { |t| inner.is_a?(t) }
          "(#{body})"
        else
          body
        end
      end

      def fmt_body(body) = body.nil? || body.empty? ? "" : ";#{body}"

      def binary_operator_call?(node)
        node.is_a?(Prism::CallNode) && node.receiver &&
          node.arguments&.arguments&.size == 1 && BINARY_OPERATORS.include?(node.name)
      end

      def setter_call?(node)
        name = node.name.to_s
        node.receiver && name.end_with?('=') && name.size > 1 &&
          !%w[== != <= >= ===].include?(name) && name != '[]='
      end

      def node_returns_bot?(node)
        case node
        when Prism::ReturnNode, Prism::BreakNode, Prism::NextNode then true
        when Prism::CallNode then node.name == :raise || node.name == :fail
        else false
        end
      end

      def rescue_var_used?(rescue_node)
        # only called when the (name-bearing) reference is present
        var = rescue_node.reference.name # steep:ignore NoMethod
        return false unless rescue_node.statements
        prism_traverse(rescue_node.statements) { |n|
          return true if n.is_a?(Prism::LocalVariableReadNode) && n.name == var
        }
        false
      end

      def block_uses_it?(body)
        return false unless body
        prism_traverse(body) { |n| return true if n.is_a?(Prism::ItLocalVariableReadNode) }
        false
      end

      def prism_traverse(node, &block)
        return unless node
        yield node
        node.compact_child_nodes.each { |child| prism_traverse(child, &block) }
      end
    end
  end
end
