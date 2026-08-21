# frozen_string_literal: true

module Ryac
  module AnalysisPhases
    def resolve_method_aliases_and_transforms(prism_root)
      alias_map = {} #: Hash[location_key, Symbol]
      transform_map = {} #: Hash[location_key, String]
      suppressed_alias_keys = [] #: Array[location_key]
      AstUtils.each_node(prism_root) do |node|
        next unless node.is_a?(Prism::CallNode)

        if node.receiver
          shorter = METHOD_ALIASES[node.name]
          alias_map[AstUtils.location_key(node)] = shorter if shorter && @oracle.receiver_responds_to?(node, shorter)
        else
          shorter = KERNEL_ALIASES[node.name]
          alias_map[AstUtils.location_key(node)] = shorter if shorter
        end

        if node.receiver && (node.arguments.nil? || node.arguments.arguments.empty?)
          METHOD_TRANSFORMS.each do |(mid, type_name), replacement|
            next unless mid == node.name
            if @oracle.receiver_within_type?(node, type_name)
              transform_map[AstUtils.location_key(node)] = replacement
              break
            end
          end
        end

        register_size_comparison(node, transform_map, suppressed_alias_keys)
      end
      # A comparison transform swallows its inner size call whole — an
      # alias patch on that call would overlap it.
      suppressed_alias_keys.each { |k| alias_map.delete(k) }
      [alias_map, transform_map]
    end

    private

    # `.size==0` (and !=0 / >0) against a proven receiver collapses to the
    # literal comparison. Registered on the comparison node; the renamer
    # patches from the data receiver through the comparison's end.
    def register_size_comparison(node, transform_map, suppressed_alias_keys)
      return unless SIZE_COMPARISON_OPS.key?(node.name)

      inner = node.receiver
      return unless inner.is_a?(Prism::CallNode)
      return unless inner.receiver && inner.call_operator_loc && !inner.safe_navigation?
      return unless inner.arguments.nil? && inner.block.nil?

      types = SIZE_QUERY_MIDS[inner.name]
      return unless types

      args = node.arguments&.arguments
      return unless args && args.size == 1 && args[0].is_a?(Prism::IntegerNode) && args[0].value == 0

      types.each do |type_name|
        next unless @oracle.receiver_within_type?(inner, type_name)
        transform_map[AstUtils.location_key(node)] = SIZE_COMPARISON_TRANSFORMS.fetch([node.name, type_name])
        suppressed_alias_keys << AstUtils.location_key(inner)
        break
      end
    end
  end
end
