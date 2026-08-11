# frozen_string_literal: true

module Ryac
  def resolve_method_aliases_and_transforms(prism_root)
    alias_map = {}
    transform_map = {}
    AstUtils.each_node(prism_root) do |node|
      next unless node.is_a?(Prism::CallNode)

      shorter = METHOD_ALIASES[node.name]
      if shorter
        if node.receiver
          alias_map[AstUtils.location_key(node)] = shorter if @oracle.receiver_responds_to?(node, shorter)
        else
          alias_map[AstUtils.location_key(node)] = shorter
        end
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
    end
    [alias_map, transform_map]
  end
end
