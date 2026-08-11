# frozen_string_literal: true

require 'set'

module Ryac
  module Pipeline
    # Level 2: Constant aliasing via source patching.
    class ConstantAliaser
      include RenamePatcher

      def self.collect_patches_from(prism_ast, patches, analysis, _kwargs = nil)
        class_module_cpath_offsets = Set.new
        new.run_collect(prism_ast, patches, analysis, class_module_cpath_offsets)
      end

      def self.postprocess(result, analysis, aliases_str, preamble_str)
        if analysis.constant_mapping
          prefix_decls = analysis.constant_mapping.generate_prefix_declarations
          preamble_str = [preamble_str, prefix_decls.join(';')].reject(&:empty?).join(';') if prefix_decls.any?

          alias_decls = analysis.constant_mapping.generate_alias_declarations
          aliases_str = [aliases_str, alias_decls.join(';')].reject(&:empty?).join(';') if alias_decls.any?
        end

        [result, aliases_str, preamble_str]
      end

      def run_collect(node, patches, analysis, class_module_cpath_offsets)
        @class_module_cpath_offsets = class_module_cpath_offsets
        collect_patches(node, patches, analysis)
      end

      private

      def collect_patches(node, patches, analysis)
        walk_prism(node) do |subnode|
          case subnode
          when Prism::ConstantReadNode
            patch_constant_ref(subnode, patches, analysis)
          when Prism::ConstantPathNode
            patch_constant_ref(subnode, patches, analysis)
            next :skip_children
          when Prism::ConstantWriteNode
            patch_constant_write(subnode, patches, analysis)
          when Prism::ConstantTargetNode
            # `A, B = ...` — Prism models each target as a ConstantTargetNode,
            # not a ConstantWriteNode. TypeProf still reports one constant per
            # target at the same location, so without this the references get
            # renamed while the definitions keep their original names.
            patch_constant_write(subnode, patches, analysis)
          when Prism::ConstantPathWriteNode
            patch_constant_path_write(subnode, patches, analysis)
          when Prism::ClassNode
            patch_class_node(subnode, patches, analysis)
          when Prism::ModuleNode
            patch_module_node(subnode, patches, analysis)
          when Prism::DefNode
            patch_def_receiver(subnode.receiver, patches, analysis) if subnode.receiver && !subnode.receiver.is_a?(Prism::SelfNode)
          end
        end
      end

      def patch_constant_ref(node, patches, analysis)
        return if @class_module_cpath_offsets.include?(node.location.start_offset)

        key = prism_location_key(node)
        resolved_cpath = analysis.const_resolution_map[key]
        full_path = analysis.const_full_path_map[key]
        prefix_alias = full_path && analysis.constant_mapping&.short_name_for_prefix(full_path)

        if resolved_cpath && analysis.constant_mapping&.user_defined_path?(resolved_cpath)
          short = if node.is_a?(Prism::ConstantReadNode)
            # Bare name reference (e.g., CONST) — use only the leaf short name.
            # Expanding to a fully qualified path would break constants defined
            # in `class << self` (metaclass constants are not accessible as Foo::X).
            analysis.constant_mapping.short_name_for_path(resolved_cpath) || node.name.to_s
          else
            get_short_cpath(resolved_cpath, analysis)
          end
          loc = node.location
          patches << { start: loc.start_offset, end: loc.end_offset, replacement: short }
        elsif node.is_a?(Prism::ConstantPathNode) && resolved_cpath &&
              (short = build_renamed_via_user_prefix(node, analysis))
          loc = node.location
          patches << { start: loc.start_offset, end: loc.end_offset, replacement: short }
        elsif prefix_alias
          short = "#{prefix_alias}::#{node.name}"
          loc = node.location
          patches << { start: loc.start_offset, end: loc.end_offset, replacement: short }
        end
      end

      def patch_constant_write(node, patches, analysis)
        key = prism_location_key(node)
        static_cpath = analysis.const_write_cpath_map[key]
        return unless static_cpath

        short_name = analysis.constant_mapping.short_name_for_path(static_cpath)
        return unless short_name

        # A ConstantTargetNode is entirely the name; a ConstantWriteNode also
        # spans `= value`, so only its name_loc belongs to us.
        name_loc = node.is_a?(Prism::ConstantTargetNode) ? node.location : node.name_loc
        patches << { start: name_loc.start_offset, end: name_loc.end_offset, replacement: short_name }
      end

      def patch_constant_path_write(node, patches, analysis)
        key = prism_location_key(node)
        static_cpath = analysis.const_write_cpath_map[key]
        return unless static_cpath

        path_str = render_short_cpath(static_cpath, analysis)
        target_loc = node.target.location
        patches << { start: target_loc.start_offset, end: target_loc.end_offset, replacement: path_str }
        @class_module_cpath_offsets << target_loc.start_offset
        mark_constant_children(node.target)
      end

      def patch_class_node(node, patches, analysis)
        key = prism_location_key(node)
        patch_definition_path(node, patches, analysis.class_cpath_map[key], analysis)

        if node.superclass
          superclass_path = analysis.superclass_resolution_map[key]
          superclass_path ||= analysis.const_resolution_map[prism_location_key(node.superclass)]
          if superclass_path
            short = get_short_cpath(superclass_path, analysis)
            sc_loc = node.superclass.location
            patches << { start: sc_loc.start_offset, end: sc_loc.end_offset, replacement: short }
            @class_module_cpath_offsets << sc_loc.start_offset
            mark_constant_children(node.superclass)
          end
        end
      end

      def patch_module_node(node, patches, analysis)
        patch_definition_path(node, patches, analysis.class_cpath_map[prism_location_key(node)], analysis)
      end

      # A definition's written path names the class relative to its lexical
      # nesting, and the enclosing modules are renamed right along with it —
      # so the renamed spelling only needs the written segments' short names.
      # Re-qualifying with the full path (`module A; class A::B`) costs bytes
      # and says nothing the nesting doesn't already say: `class B` inside
      # `module A` creates and reopens exactly A::B.
      def patch_definition_path(node, patches, class_cpath, analysis)
        return unless class_cpath

        # class_cpath exists only when path_segments succeeded on this node,
        # and in the absolute case it equals the segments outright.
        segments, = Nesting.path_segments(node.constant_path)
        rendered = render_short_cpath(class_cpath, analysis, from: class_cpath.size - segments.size)
        if rendered != node.constant_path.slice
          cpath_loc = node.constant_path.location
          patches << { start: cpath_loc.start_offset, end: cpath_loc.end_offset, replacement: rendered }
        end

        @class_module_cpath_offsets << node.constant_path.location.start_offset
        mark_constant_children(node.constant_path)
      end

      # Each prefix of the cpath may carry its own short name; render from
      # `from` onward, falling back to the original segment where none was
      # assigned.
      def render_short_cpath(cpath, analysis, from: 0)
        (from...cpath.size).map { |i|
          analysis.constant_mapping.short_name_for_path(cpath[0..i]) || cpath[i].to_s
        }.join('::')
      end

      def mark_constant_children(node)
        case node
        when Prism::ConstantPathNode
          @class_module_cpath_offsets << node.location.start_offset
          mark_constant_children(node.parent) if node.parent
        when Prism::ConstantReadNode
          @class_module_cpath_offsets << node.location.start_offset
        end
      end

      def build_renamed_via_user_prefix(node, analysis)
        parent_node = node.parent
        return nil unless parent_node

        parent_key = prism_location_key(parent_node)
        parent_resolved = analysis.const_resolution_map[parent_key]
        return nil unless parent_resolved

        if analysis.constant_mapping.user_defined_path?(parent_resolved)
          parent_short = if parent_node.is_a?(Prism::ConstantReadNode)
            analysis.constant_mapping.short_name_for_path(parent_resolved) || parent_node.name.to_s
          else
            get_short_cpath(parent_resolved, analysis)
          end
          "#{parent_short}::#{node.name}"
        elsif parent_node.is_a?(Prism::ConstantPathNode)
          parent_renamed = build_renamed_via_user_prefix(parent_node, analysis)
          parent_renamed ? "#{parent_renamed}::#{node.name}" : nil
        end
      end

      def get_short_cpath(cpath, analysis)
        if analysis.constant_mapping.user_defined_path?(cpath)
          render_short_cpath(cpath, analysis)
        else
          cpath.map(&:to_s).join('::')
        end
      end

      def patch_def_receiver(receiver, patches, analysis)
        return unless analysis.constant_mapping

        @class_module_cpath_offsets.add(receiver.location.start_offset)
        key = prism_location_key(receiver)
        resolved_cpath = case receiver
                         when Prism::ConstantReadNode
                           analysis.const_resolution_map[key] || [receiver.name]
                         when Prism::ConstantPathNode
                           analysis.const_resolution_map[key]
                         end
        return unless resolved_cpath && analysis.constant_mapping.user_defined_path?(resolved_cpath)

        short = get_short_cpath(resolved_cpath, analysis)
        loc = receiver.location
        patches << { start: loc.start_offset, end: loc.end_offset, replacement: short }
      end
    end
  end
end
