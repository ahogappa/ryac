# frozen_string_literal: true

module Ryac
  module Pipeline
    # Configurable variable renaming stage.
    # Default (no features): renames locals only.
    # features: { keywords: true } → locals + keywords (Level 3)
    # features: { keywords: true, ivars: true, cvars: true, gvars: true } → all variables (Level 4)
    class VariableRenamer < Stage
      include RenamePatcher

      FEATURES = { locals: true, keywords: false, ivars: false, cvars: false, gvars: false }.freeze

      def needs_analysis? = true

      def initialize(features: {})
        @features = FEATURES.merge(features)
      end

      def collect(ctx, patches)
        analysis = analysis(ctx)
        rename_map = build_rename_map(analysis)
        block_param_names_map = analysis.block_param_names_map
        collect_patches(ctx.ast, patches, analysis, rename_map, block_param_names_map)
      end

      private

      def build_rename_map(analysis)
        map = {} #: Hash[location_key, String]
        map.merge!(analysis.local_rename_entries) if @features[:locals]
        map.merge!(analysis.keyword_rename_entries) if @features[:keywords]
        if @features[:ivars]
          map.merge!(analysis.ivar_rename_entries)
          map.merge!(analysis.attr_ivar_entries) if @features[:attr_ivars]
        end
        map.merge!(analysis.cvar_rename_entries) if @features[:cvars]
        map.merge!(analysis.gvar_rename_entries) if @features[:gvars]
        map
      end

      def collect_patches(node, patches, analysis, rename_map, block_param_names_map)
        callback = proc { |subnode| handle_node(subnode, patches, analysis, rename_map, block_param_names_map) } #: ^(Prism::Node) -> (Symbol | nil)
        walk_prism(node, &callback)
      end

      def handle_node(subnode, patches, analysis, rename_map, block_param_names_map)
        case subnode
        # Local variables
        when Prism::LocalVariableReadNode
          patch_variable(subnode, patches, rename_map)
        when Prism::LocalVariableWriteNode
          patch_variable_name_only(subnode, patches, rename_map)
        when Prism::LocalVariableTargetNode
          patch_variable(subnode, patches, rename_map)
        when Prism::LocalVariableOperatorWriteNode,
             Prism::LocalVariableOrWriteNode,
             Prism::LocalVariableAndWriteNode
          patch_variable_name_only(subnode, patches, rename_map)

        # Instance variables
        when Prism::InstanceVariableReadNode
          patch_variable(subnode, patches, rename_map) if @features[:ivars]
        when Prism::InstanceVariableWriteNode
          patch_variable_name_only(subnode, patches, rename_map) if @features[:ivars]
        when Prism::InstanceVariableOperatorWriteNode,
             Prism::InstanceVariableOrWriteNode,
             Prism::InstanceVariableAndWriteNode
          patch_variable_name_only(subnode, patches, rename_map) if @features[:ivars]
        when Prism::InstanceVariableTargetNode
          patch_variable(subnode, patches, rename_map) if @features[:ivars]

        # Class variables
        when Prism::ClassVariableReadNode
          patch_variable(subnode, patches, rename_map) if @features[:cvars]
        when Prism::ClassVariableWriteNode
          patch_variable_name_only(subnode, patches, rename_map) if @features[:cvars]
        when Prism::ClassVariableOperatorWriteNode,
             Prism::ClassVariableOrWriteNode,
             Prism::ClassVariableAndWriteNode
          patch_variable_name_only(subnode, patches, rename_map) if @features[:cvars]
        when Prism::ClassVariableTargetNode
          patch_variable(subnode, patches, rename_map) if @features[:cvars]

        # Global variables
        when Prism::GlobalVariableReadNode
          patch_variable(subnode, patches, rename_map) if @features[:gvars]
        when Prism::GlobalVariableWriteNode
          patch_variable_name_only(subnode, patches, rename_map) if @features[:gvars]
        when Prism::GlobalVariableOperatorWriteNode,
             Prism::GlobalVariableOrWriteNode,
             Prism::GlobalVariableAndWriteNode
          patch_variable_name_only(subnode, patches, rename_map) if @features[:gvars]
        when Prism::GlobalVariableTargetNode
          patch_variable(subnode, patches, rename_map) if @features[:gvars]

        # Def params
        when Prism::DefNode
          patch_def_params(subnode, patches, analysis, :param_names)

        # Block params
        when Prism::CallNode
          patch_block_params(subnode, patches, block_param_names_map)

        # For node — patch index and walk body/collection manually to avoid
        # double-patching the index via LocalVariableTargetNode handler
        when Prism::ForNode
          patch_for_node(subnode, patches, analysis, :for_index_mangled)
          callback = proc { |n| handle_node(n, patches, analysis, rename_map, block_param_names_map) } #: ^(Prism::Node) -> (Symbol | nil)
          walk_prism(subnode.collection, &callback)
          walk_prism(subnode.statements, &callback)
          :skip_children

        # Hash assoc shorthand
        when Prism::KeywordHashNode
          callback = proc { |n| handle_node(n, patches, analysis, rename_map, block_param_names_map) } #: ^(Prism::Node) -> (Symbol | nil)
          patch_keyword_hash(subnode, patches, rename_map, &callback)
          :skip_children
        when Prism::AssocNode
          patch_assoc(subnode, patches, rename_map)
        end
      end
    end
  end
end
