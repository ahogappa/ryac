# frozen_string_literal: true

module Ryac
  module Pipeline
    # Method renaming: renames method definitions and call sites.
    #
    # policy: :aggressive (default) renames every group the exclusion
    # passes leave standing, folding unresolved same-name calls and blind
    # defs into the groups they probably belong to. :safe renames only
    # groups whose every caller type inference actually resolved — an
    # unresolved call excludes its name, an uncalled def keeps its name
    # (it is either dead or someone outside the program calls it), and a
    # name that appears inside a string literal keeps its spelling (eval
    # and send-by-string read strings, not the syntax tree).
    class MethodRenamer < Stage
      include RenamePatcher

      def initialize(policy: :aggressive)
        @policy = policy
      end

      def analysis_options = { method_policy: @policy }

      def needs_analysis? = true

      def collect(ctx, patches)
        analysis = analysis(ctx)
        rename_map = analysis.rename_map
        method_alias_map = analysis.method_alias_map
        @negated_transforms = {}
        @source_bytes = analysis.source.content
        collect_patches(ctx.ast, patches, analysis, rename_map, method_alias_map)
      end

      private

      def collect_patches(node, patches, analysis, rename_map, method_alias_map)
        # @type var callback: ^(Prism::Node) -> void
        callback = proc { |subnode|
          handle_node(subnode, patches, analysis, rename_map, method_alias_map)
        }
        walk_prism(node, &callback)
      end

      def handle_node(subnode, patches, analysis, rename_map, method_alias_map)
        case subnode
        when Prism::DefNode
          patch_def_name(subnode, patches, rename_map)

        when Prism::CallNode
          patch_call_node(subnode, patches, rename_map, method_alias_map, analysis)

        when Prism::CallOperatorWriteNode,
             Prism::CallOrWriteNode,
             Prism::CallAndWriteNode
          patch_call_operator_write(subnode, patches, rename_map, method_alias_map)
        end
      end

      def patch_def_name(node, patches, rename_map)
        key = prism_location_key(node)
        short = rename_map[key]
        return unless short

        name_loc = node.name_loc
        patches << { start: name_loc.start_offset, end: name_loc.end_offset, replacement: short }
      end

      def patch_call_node(node, patches, rename_map, method_alias_map, analysis)
        # Detect negated transforms: !receiver.empty? → receiver!=[]
        # The ! CallNode is visited before its children, so we mark the inner
        # node here and negate the transform when it's applied later.
        if node.name == :"!" && node.receiver.is_a?(Prism::CallNode)
          inner = node.receiver
          inner_key = prism_location_key(inner)
          transform = analysis.method_transform_map[inner_key]
          if transform&.start_with?('==') && inner.call_operator_loc && !inner.safe_navigation?
            @negated_transforms[inner_key] = true
            patches << { start: node.location.start_offset, end: inner.location.start_offset, replacement: '' }
          end
        end

        key = prism_location_key(node)

        # Meta calls are structural, not plain calls: attr declarations are
        # rewritten wholesale by AttrDeclShorten, and include must keep its
        # name. Renaming or transforming them here would corrupt them.
        return if analysis.meta_node_map[key]

        # Structural transforms (e.g. .first → [0], .empty? → ==[])
        transform = analysis.method_transform_map[key]
        if transform && node.call_operator_loc && !node.safe_navigation?
          replacement = @negated_transforms[key] ? "!#{transform[1..]}" : transform
          end_offset = node.location.end_offset
          # Consume trailing spaces around ternary ? when no longer needed
          # e.g. .empty? ? "x" → ==[]?"x" since ] is not a name char
          if @source_bytes.getbyte(end_offset) == 0x20 && @source_bytes.getbyte(end_offset + 1) == 0x3F # ' ' and '?'
            end_offset += 2 # consume space + ternary ?
            end_offset += 1 if @source_bytes.getbyte(end_offset) == 0x20 # consume space after ?
            replacement = "#{replacement}?"
          end
          # call_operator_loc was checked at the top of this branch
          patches << { start: node.call_operator_loc.start_offset, end: end_offset, replacement: replacement } # steep:ignore NoMethod
          return
        elsif transform && !node.call_operator_loc && node.receiver.is_a?(Prism::CallNode)
          # A comparison-shape transform (.size==0 → ==[]), registered on
          # the operator call whose receiver is the size query: the patch
          # swallows the query and the comparison together.
          receiver_end = node.receiver.receiver.location.end_offset # steep:ignore NoMethod
          patches << { start: receiver_end, end: node.location.end_offset, replacement: transform }
          return
        end

        return unless node.message_loc

        short = rename_map[key]

        # send/public_send/__send__: patch the symbol argument, not the method name
        if short && SEND_METHODS.include?(node.name)
          patch_send_symbol(node, patches, short)
          return
        end

        alias_name = method_alias_map[key]&.to_s
        replacement = short || alias_name
        return unless replacement

        if replacement.end_with?('=') && !replacement.end_with?('==') &&
           node.name.to_s.end_with?('=') && !node.name.to_s.end_with?('==')
          msg_slice = node.message_loc.slice
          replacement = replacement.chomp('=') unless msg_slice.end_with?('=')
        end

        end_offset = node.message_loc.end_offset
        # The compactor separates a ?/!-ending name from an =-starting
        # operator with one protective space. A rename that drops the ?/!
        # must take the space with it — left behind, re-minification removes
        # it and the self-host fixed point drifts by a byte per site.
        if node.name.to_s.end_with?('?', '!') && !replacement.end_with?('?', '!') &&
           @source_bytes.getbyte(end_offset) == 0x20 && @source_bytes.getbyte(end_offset + 1) == 0x3D # ' ' then '='
          end_offset += 1
        end
        patches << { start: node.message_loc.start_offset, end: end_offset, replacement: replacement }
      end

      SEND_METHODS = %i[send __send__ public_send].freeze

      def patch_send_symbol(node, patches, short_name)
        first_arg = node.arguments&.arguments&.first
        return unless first_arg.is_a?(Prism::SymbolNode)

        loc = first_arg.location
        patches << { start: loc.start_offset, end: loc.end_offset, replacement: ":#{short_name}" }
      end

      def patch_call_operator_write(node, patches, rename_map, method_alias_map)
        return unless node.message_loc
        key = prism_location_key(node)
        short = rename_map[key] || method_alias_map[key]&.to_s
        return unless short
        short = short.chomp('=') if short.end_with?('=') && !short.end_with?('==')
        patches << { start: node.message_loc.start_offset, end: node.message_loc.end_offset, replacement: short }
      end
    end
  end
end
