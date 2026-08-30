# frozen_string_literal: true

module Ryac
  module AnalysisPhases
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
        when Prism::ClassVariableReadNode, *CVAR_WRITE_NODES
          # @type var node: Prism::ClassVariableReadNode | cvar_write_node
          @cvar_rename_mapping.add_site(cpath, node.name, node)
        end
      end
    end

    def scan_dynamic_cvar_access(prism_root)
      scan_dynamic_sigil_access(prism_root, DYNAMIC_CVAR_METHODS, @cvar_rename_mapping)
    end

    def merge_inherited_cvars
      merge_inherited_sites(@cvar_rename_mapping)
    end
  end
end
