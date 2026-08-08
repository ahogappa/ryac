# frozen_string_literal: true

module RubyMinify
  DYNAMIC_CVAR_METHODS = %i[
    class_variable_get class_variable_set
    class_variable_defined? class_variables
    remove_class_variable
  ].freeze

  CVAR_WRITE_NODES = [
    Prism::ClassVariableWriteNode,
    Prism::ClassVariableTargetNode,
    Prism::ClassVariableOperatorWriteNode,
    Prism::ClassVariableOrWriteNode,
    Prism::ClassVariableAndWriteNode
  ].freeze

  def collect_cvar_definitions(prism_root)
    Nesting.each(prism_root) do |node, cpath, _singleton|
      case node
      when Prism::ClassVariableReadNode
        @cvar_rename_mapping.add_read_site(cpath, node.name, node)
      when *CVAR_WRITE_NODES
        @cvar_rename_mapping.add_write_site(cpath, node.name, node)
      end
    end
  end

  def scan_dynamic_cvar_access(prism_root)
    Nesting.each(prism_root) do |node, cpath, _singleton|
      next unless node.is_a?(Prism::CallNode)
      next unless DYNAMIC_CVAR_METHODS.include?(node.name)

      recv = node.receiver
      if recv.nil? || recv.is_a?(Prism::SelfNode)
        @cvar_rename_mapping.exclude_cpath(cpath)
      end
    end
  end

  def merge_inherited_cvars
    cpaths = []
    @cvar_rename_mapping.each_canonical_cpath { |c| cpaths << c }
    cpaths.each do |cpath|
      @oracle.each_ancestor_cpath(cpath, false) do |ancestor_cpath|
        next if ancestor_cpath == cpath
        @cvar_rename_mapping.merge_with_ancestor(cpath, ancestor_cpath)
      end
    end
  end
end
