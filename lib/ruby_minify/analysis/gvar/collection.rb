# frozen_string_literal: true

module RubyMinify
  def collect_gvar_definitions(nodes)
    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::GlobalVariableReadNode,
           TypeProf::Core::AST::GlobalVariableWriteNode
        @gvar_rename_mapping.add_site(node.var, node)
      end
    end
  end

  def scan_alias_globals(nodes)
    nodes.traverse do |event, node|
      next unless event == :enter
      next unless node.is_a?(TypeProf::Core::AST::AliasGlobalVariableNode)

      raw = AstUtils.prism_node(node)
      new_name = raw.new_name.slice.to_sym
      old_name = raw.old_name.slice.to_sym
      @gvar_rename_mapping.exclude_name(new_name)
      @gvar_rename_mapping.exclude_name(old_name)
    end
  end
end
