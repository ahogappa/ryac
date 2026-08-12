# frozen_string_literal: true

module Ryac
  module Pipeline
    # Shared infrastructure for L2-L5 rename pipeline stages.
    # Each stage includes this module and implements its own collect_patches.
    module RenamePatcher
      private

      def apply_patches(source, patches)
        result = source.b.dup
        patches.sort_by { |p| -p[:start] }.each do |patch|
          result[patch[:start]...patch[:end]] = patch[:replacement].b
        end
        result.force_encoding('UTF-8')
      end

      def walk_prism(node, &block)
        return unless node
        result = yield node
        return if result == :skip_children

        children = node.compact_child_nodes
        if node.is_a?(Prism::MatchWriteNode)
          children = children.reject { |c| c.is_a?(Prism::LocalVariableTargetNode) }
        end
        children.each { |child| walk_prism(child, &block) }
      end

      # Same key the analysis stored the rename under. Kept as its own name
      # because the patchers only ever pass Prism nodes, but it must not grow a
      # second implementation — the two sides sharing one definition is the
      # point.
      def prism_location_key(node)
        AstUtils.location_key(node)
      end

      def patch_variable(node, patches, rename_map)
        key = prism_location_key(node)
        short = rename_map[key]
        return unless short

        loc = node.location
        patches << { start: loc.start_offset, end: loc.end_offset, replacement: short }
      end

      def patch_variable_name_only(node, patches, rename_map)
        key = prism_location_key(node)
        short = rename_map[key]
        return unless short

        name_loc = node.name_loc
        patches << { start: name_loc.start_offset, end: name_loc.end_offset, replacement: short }
      end

      def patch_def_params(node, patches, analysis, param_names_key)
        return unless node.parameters

        syntax_key = [node.location.start_line, node.location.start_column] #: [Integer, Integer]
        data = analysis.syntax_data[syntax_key]
        return unless data

        # any? rather than empty?: `empty?` on a receiver TypeProf can prove
        # is a Hash gets rewritten to `=={}` — but only when it can prove it,
        # and whether it can differs between the original and the minified
        # text. Self-hosting then never reaches a fixed point. `any?` has no
        # such rewrite.
        param_names = data[param_names_key] || {} #: Hash[Symbol, String]
        return unless param_names.any?

        params = node.parameters
        patch_required_params(params.requireds, param_names, patches)
        patch_optional_params(params.optionals, param_names, patches)
        patch_rest_param(params.rest, param_names, patches)
        patch_post_params(params.posts, param_names, patches)
        patch_keyword_params(params.keywords, param_names, patches)
        patch_keyword_rest(params.keyword_rest, param_names, patches)
        patch_block_param_node(params.block, param_names, patches)
      end

      def patch_required_params(requireds, param_names, patches)
        return unless requireds
        requireds.each do |p|
          if p.is_a?(Prism::MultiTargetNode)
            patch_multi_target_params(p, param_names, patches)
          elsif p.is_a?(Prism::RequiredParameterNode)
            short = param_names[p.name]
            next unless short && short != p.name.to_s
            patches << { start: p.location.start_offset, end: p.location.end_offset, replacement: short }
          end
        end
      end

      def patch_multi_target_params(node, param_names, patches)
        node.lefts.each do |p|
          if p.is_a?(Prism::RequiredParameterNode)
            short = param_names[p.name]
            next unless short && short != p.name.to_s
            patches << { start: p.location.start_offset, end: p.location.end_offset, replacement: short }
          elsif p.is_a?(Prism::MultiTargetNode)
            patch_multi_target_params(p, param_names, patches)
          end
        end
        if node.rest.is_a?(Prism::SplatNode) &&
           node.rest.expression.is_a?(Prism::RequiredParameterNode)
          p = node.rest.expression
          short = param_names[p.name]
          if short && short != p.name.to_s
            patches << { start: p.location.start_offset, end: p.location.end_offset, replacement: short }
          end
        end
      end

      def patch_optional_params(optionals, param_names, patches)
        return unless optionals
        optionals.each do |p|
          short = param_names[p.name]
          next unless short && short != p.name.to_s
          patches << { start: p.name_loc.start_offset, end: p.name_loc.end_offset, replacement: short }
        end
      end

      def patch_rest_param(rest, param_names, patches)
        return unless rest.is_a?(Prism::RestParameterNode) && rest.name
        short = param_names[rest.name]
        return unless short && short != rest.name.to_s
        # rest.name checked above: a named rest param always carries name_loc,
        # though Prism types it as nullable.
        patches << { start: rest.name_loc.start_offset, end: rest.name_loc.end_offset, replacement: short } # steep:ignore NoMethod
      end

      def patch_post_params(posts, param_names, patches)
        return unless posts
        posts.each do |p|
          next unless p.is_a?(Prism::RequiredParameterNode)
          short = param_names[p.name]
          next unless short && short != p.name.to_s
          patches << { start: p.location.start_offset, end: p.location.end_offset, replacement: short }
        end
      end

      def patch_keyword_params(keywords, param_names, patches)
        return unless keywords
        keywords.each do |p|
          short = param_names[p.name]
          next unless short && short != p.name.to_s
          patches << { start: p.name_loc.start_offset, end: p.name_loc.end_offset, replacement: "#{short}:" }
        end
      end

      def patch_keyword_rest(keyword_rest, param_names, patches)
        return unless keyword_rest.is_a?(Prism::KeywordRestParameterNode) && keyword_rest.name
        short = param_names[keyword_rest.name]
        return unless short && short != keyword_rest.name.to_s
        # keyword_rest.name checked above: a named **rest always carries
        # name_loc, though Prism types it as nullable.
        patches << { start: keyword_rest.name_loc.start_offset, end: keyword_rest.name_loc.end_offset, replacement: short } # steep:ignore NoMethod
      end

      def patch_block_param_node(block, param_names, patches)
        return unless block.is_a?(Prism::BlockParameterNode) && block.name
        short = param_names[block.name]
        return unless short && short != block.name.to_s
        # block.name checked above: a named &block param always carries
        # name_loc, though Prism types it as nullable.
        patches << { start: block.name_loc.start_offset, end: block.name_loc.end_offset, replacement: short } # steep:ignore NoMethod
      end

      def patch_block_params(node, patches, block_param_names_map)
        return unless node.block.is_a?(Prism::BlockNode)
        block = node.block
        return unless block.parameters.is_a?(Prism::BlockParametersNode)

        key = prism_location_key(node)
        param_map = block_param_names_map[key]
        return unless param_map

        mangled_values = param_map.values
        block_params = block.parameters.parameters
        has_non_required = block_params && (
          block_params.optionals&.any? ||
          block_params.rest ||
          block_params.posts&.any? ||
          block_params.keywords&.any? ||
          block_params.keyword_rest ||
          block_params.block
        )
        if mangled_values.any? { |v| v.match?(/^_\d+$/) } && !has_non_required
          bp_loc = block.parameters.location
          patches << { start: bp_loc.start_offset, end: bp_loc.end_offset, replacement: '' }
          return
        end

        block_params = block.parameters.parameters
        return unless block_params

        patch_required_params(block_params.requireds, param_map, patches)
        patch_optional_params(block_params.optionals, param_map, patches)
        patch_rest_param(block_params.rest, param_map, patches)
        patch_post_params(block_params.posts, param_map, patches)
        patch_keyword_params(block_params.keywords, param_map, patches)
        patch_keyword_rest(block_params.keyword_rest, param_map, patches)
        patch_block_param_node(block_params.block, param_map, patches)
      end

      def patch_for_node(node, patches, analysis, mangled_key)
        syntax_key = [node.location.start_line, node.location.start_column] #: [Integer, Integer]
        data = analysis.syntax_data[syntax_key]
        return unless data

        target_name = data[mangled_key] #: String?
        return unless target_name

        idx = node.index
        return unless idx.is_a?(Prism::LocalVariableTargetNode)
        patches << { start: idx.location.start_offset, end: idx.location.end_offset, replacement: target_name }
      end

      def patch_assoc(node, patches, rename_map, keyword_arg: false)
        key_node = node.key
        val_node = node.value

        return unless key_node.is_a?(Prism::SymbolNode)
        return unless key_node.value.to_s.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)

        original_key = key_node.value.to_s
        renamed_key = rename_map[prism_location_key(key_node)]

        if val_node.is_a?(Prism::ImplicitNode)
          inner = val_node.value
          if inner.is_a?(Prism::LocalVariableReadNode)
            mangled_var = rename_map[prism_location_key(inner)] || inner.name.to_s
            key_name = keyword_arg ? (renamed_key || original_key) : original_key
            if key_name == mangled_var
              if key_name != original_key
                patches << { start: key_node.location.start_offset, end: val_node.location.end_offset,
                             replacement: "#{key_name}:" }
              end
            else
              sep = mangled_var.start_with?(':') ? ': ' : ':'
              patches << { start: key_node.location.start_offset, end: val_node.location.end_offset,
                           replacement: "#{key_name}#{sep}#{mangled_var}" }
            end
          else
            if keyword_arg && renamed_key
              patches << { start: key_node.location.start_offset, end: val_node.location.end_offset,
                           replacement: "#{renamed_key}:" }
            end
          end
          return :skip_children
        end

        key_name = renamed_key || original_key

        if val_node.is_a?(Prism::LocalVariableReadNode)
          mangled_var = rename_map[prism_location_key(val_node)] || val_node.name.to_s
          if key_name == mangled_var
            patches << { start: key_node.location.start_offset, end: val_node.location.end_offset,
                         replacement: "#{key_name}:" }
            return :skip_children
          end
        end

        if renamed_key
          loc = key_node.location
          suffix = loc.slice.end_with?(':') ? ':' : ''
          patches << { start: loc.start_offset, end: loc.end_offset, replacement: "#{renamed_key}#{suffix}" }
        end
      end

      def patch_keyword_hash(node, patches, rename_map, &block)
        node.elements.each do |elem|
          if elem.is_a?(Prism::AssocNode)
            result = patch_assoc(elem, patches, rename_map, keyword_arg: true)
            if result != :skip_children
              elem.compact_child_nodes.each { |child| walk_prism(child, &block) }
            end
          else
            walk_prism(elem, &block)
          end
        end
      end

    end
  end
end
