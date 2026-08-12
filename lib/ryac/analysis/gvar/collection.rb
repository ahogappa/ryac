# frozen_string_literal: true

module Ryac
  GVAR_NODES = [
    Prism::GlobalVariableReadNode,
    Prism::GlobalVariableWriteNode,
    Prism::GlobalVariableTargetNode,
    Prism::GlobalVariableOperatorWriteNode,
    Prism::GlobalVariableOrWriteNode,
    Prism::GlobalVariableAndWriteNode
  ].freeze

  def collect_gvar_definitions(prism_root)
    AstUtils.each_node(prism_root) do |node|
      case node
      when *GVAR_NODES
        # @type var node: Prism::GlobalVariableReadNode | Prism::GlobalVariableWriteNode | Prism::GlobalVariableTargetNode | Prism::GlobalVariableOperatorWriteNode | Prism::GlobalVariableOrWriteNode | Prism::GlobalVariableAndWriteNode
        @gvar_rename_mapping.add_site(node.name, node)
      end
    end
  end

  # `alias $new $old` aliases the *variable*, so the two names refer to one
  # storage cell; renaming either side independently would sever them.
  def scan_alias_globals(prism_root)
    AstUtils.each_node(prism_root) do |node|
      next unless node.is_a?(Prism::AliasGlobalVariableNode)

      @gvar_rename_mapping.exclude_name(node.new_name.slice.to_sym)
      @gvar_rename_mapping.exclude_name(node.old_name.slice.to_sym)
    end
  end
end
