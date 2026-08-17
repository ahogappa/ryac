# frozen_string_literal: true

module Ryac
  def resolve_method_aliases_and_transforms(prism_root)
    alias_map = {} #: Hash[location_key, Symbol]
    transform_map = {} #: Hash[location_key, String]
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
    end
    [alias_map, transform_map]
  end
end
