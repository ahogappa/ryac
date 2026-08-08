# frozen_string_literal: true

require 'stringio'

module RubyMinify
  module Pipeline
    # Stage 3: Analysis
    # Parses source with TypeProf, builds scope mappings,
    # collects constants and their references, and freezes mappings.
    class Analyzer < Stage
      include RubyMinify

      def self.prism_only(source)
        prism_only_from_string(source.content, source: source)
      end

      def self.prism_only_from_string(content, source: nil)
        prism_result = Prism.parse(content)

        analyzer = new
        syntax_data = analyzer.syntax_data_for(prism_result.value)

        source ||= ConcatenatedSource.new(
          content: content,
          file_boundaries: [],
          original_size: content.bytesize,
          stdlib_requires: [],
          rbs_files: {}
        )

        AnalysisResult.new(
          prism_ast: prism_result.value,
          scope_mappings: {},
          constant_mapping: nil,
          rename_map: {},
          method_alias_map: {},
          method_transform_map: {},
          source: source,
          attr_rename_map: {},
          block_param_names_map: {},
          syntax_data: syntax_data,
          const_resolution_map: {},
          const_full_path_map: {},
          const_write_cpath_map: {},
          class_cpath_map: {},
          superclass_resolution_map: {},
          meta_node_map: {}
        )
      end

      def call(source)
        prism_result, nodes, genv = without_stdout_pollution { setup_typeprof(source) }
        @syntax_data = collect_syntax_data(prism_result.value)

        analyze_keywords_and_scopes(prism_result.value, nodes, genv)
        analyze_methods_phase(nodes, genv)
        method_alias_map, method_transform_map = resolve_method_aliases_and_transforms(nodes, genv)
        analyze_variables_phase(nodes, genv)

        rename_map = @method_rename_mapping.node_mapping.dup
        attr_ivar_entries = {}
        attr_rename_map = coordinate_attr_renames(nodes, genv, rename_map, attr_ivar_entries)

        analyze_constants_phase(nodes, genv)
        local_rename_entries = precompute_rename_entries(nodes)
        precompute_constant_resolution(nodes)
        precompute_meta_nodes(nodes)

        build_analysis_result(
          prism_result, source, rename_map, method_alias_map, method_transform_map,
          attr_rename_map, attr_ivar_entries, local_rename_entries
        )
      end

      def syntax_data_for(prism_ast)
        collect_syntax_data(prism_ast)
      end

      private

      # TypeProf prints diagnostics for node types it does not recognize
      # straight to stdout, which is also where the minified program is
      # written. Divert anything it emits to stderr so it can never end up
      # inside the output.
      def without_stdout_pollution
        original = $stdout
        capture = StringIO.new
        $stdout = capture
        begin
          yield
        ensure
          $stdout = original
          noise = capture.string
          $stderr.print(noise) unless noise.empty?
        end
      end

      def setup_typeprof(source)
        path = "(minify_concat)"
        content = source.content

        prism_result = Prism.parse(content)
        unless prism_result.errors.empty?
          error = prism_result.errors.first
          raise SyntaxError, "at #{path}:#{error.location.start_line}:#{error.location.start_column}: #{error.message}"
        end

        service = TypeProf::Core::Service.new({})
        source.rbs_files.each do |rbs_path, rbs_content|
          service.update_rbs_file(rbs_path, rbs_content)
        end
        service.update_rb_file(path, content)
        nodes = service.instance_variable_get(:@rb_text_nodes)[path]

        [prism_result, nodes, service.genv]
      end

      def analyze_keywords_and_scopes(prism_root, nodes, genv)
        @local_scopes = LocalScopes.new(prism_root)

        @keyword_rename_mapping = KeywordRenameMapping.new
        collect_keyword_info(nodes, genv)
        @keyword_rename_mapping.assign_short_names

        # Inline rather than through locals: a local passed as the same-named
        # keyword gets hint-aligned and collapses to shorthand, and the
        # re-minified form of that shorthand no longer carries the hint — the
        # names then oscillate between passes instead of reaching a fixed
        # point under self-hosting.
        @local_scopes.allocate(
          kw_def_map: @keyword_rename_mapping.def_node_mapping(@keyword_def_node_registry || {}),
          var_hints: @keyword_rename_mapping.build_variable_hints { |tp_node| @local_scopes.scope_id_of(tp_node) }
        )
        @local_scopes.resolve
        @scope_mappings = @local_scopes.scope_mappings
      end

      def analyze_methods_phase(nodes, genv)
        @method_rename_mapping = MethodRenameMapping.new
        collect_method_definitions(nodes, genv)
        resolve_method_calls(genv, nodes)
        collect_alias_undef_methods(nodes)
        scan_dynamic_method_references(nodes)
        collect_visibility_modifier_methods(nodes)
        @method_rename_mapping.assign_short_names(@scope_mappings, genv)
      end

      def analyze_variables_phase(nodes, genv)
        @ivar_rename_mapping = IvarRenameMapping.new
        attr_backed = collect_attr_backed_ivars(nodes)
        collect_ivar_definitions(nodes, attr_backed)
        scan_dynamic_ivar_access(nodes)
        merge_inherited_ivars(genv)
        reserve_attr_ivar_names(nodes)
        @ivar_rename_mapping.assign_short_names

        @cvar_rename_mapping = CvarRenameMapping.new
        collect_cvar_definitions(nodes)
        scan_dynamic_cvar_access(nodes)
        merge_inherited_cvars(genv)
        @cvar_rename_mapping.assign_short_names

        @gvar_rename_mapping = GvarRenameMapping.new
        collect_gvar_definitions(nodes)
        scan_alias_globals(nodes)
        @gvar_rename_mapping.assign_short_names
      end

      def analyze_constants_phase(nodes, genv)
        @constant_mapping = ConstantRenameMapping.new
        collect_constants(nodes)
        exclude_private_constants(nodes)
        count_constant_references(nodes)
        augment_constant_counts_via_typeprof(genv)
        collect_external_references(nodes)
      end

      def precompute_rename_entries(_nodes)
        @local_scopes.def_param_names.each do |key, names|
          (@syntax_data[key] ||= {})[:param_names] = names
        end
        @local_scopes.for_index_names.each do |key, name|
          data = @syntax_data[key]
          data[:for_index_mangled] = name if data&.[](:index_name)
        end
        @block_param_names_map = @local_scopes.block_param_names
        @local_scopes.rename_entries
      end

      def build_analysis_result(prism_result, source, rename_map, method_alias_map,
                                method_transform_map, attr_rename_map, attr_ivar_entries,
                                local_rename_entries)
        AnalysisResult.new(
          prism_ast: prism_result.value,
          scope_mappings: @scope_mappings,
          constant_mapping: @constant_mapping,
          rename_map: rename_map,
          method_alias_map: method_alias_map,
          method_transform_map: method_transform_map,
          source: source,
          attr_rename_map: attr_rename_map,
          block_param_names_map: @block_param_names_map,
          syntax_data: @syntax_data,
          const_resolution_map: @const_resolution_map,
          const_full_path_map: @const_full_path_map,
          const_write_cpath_map: @const_write_cpath_map,
          class_cpath_map: @class_cpath_map,
          superclass_resolution_map: @superclass_resolution_map,
          meta_node_map: @meta_node_map,
          local_rename_entries: local_rename_entries,
          keyword_rename_entries: @keyword_rename_mapping.node_mapping,
          ivar_rename_entries: @ivar_rename_mapping.node_mapping,
          attr_ivar_entries: attr_ivar_entries,
          cvar_rename_entries: @cvar_rename_mapping.node_mapping,
          gvar_rename_entries: @gvar_rename_mapping.node_mapping
        )
      end

      def walk_prism_tree(node, &block)
        return unless node
        yield node
        node.compact_child_nodes.each { |child| walk_prism_tree(child, &block) }
      end

      def precompute_constant_resolution(nodes)
        @const_resolution_map = {}
        @const_full_path_map = {}
        @const_write_cpath_map = {}
        @class_cpath_map = {}
        @superclass_resolution_map = {}

        nodes.body.traverse do |event, node|
          next unless event == :enter
          case node
          when TypeProf::Core::AST::ConstantReadNode
            key = AstUtils.location_key(node)
            resolved = resolve_constant_read_cpath(node)
            @const_resolution_map[key] = resolved
            @const_full_path_map[key] = resolved || build_constant_path(node)
          when TypeProf::Core::AST::ConstantWriteNode
            @const_write_cpath_map[AstUtils.location_key(node)] = normalize_const_write_cpath(node)
          when TypeProf::Core::AST::ClassNode
            key = AstUtils.location_key(node)
            @class_cpath_map[key] = node.static_cpath
            if node.superclass_cpath
              @superclass_resolution_map[key] = resolve_constant_path(node.superclass_cpath, node.static_cpath)
            end
          when TypeProf::Core::AST::ModuleNode
            @class_cpath_map[AstUtils.location_key(node)] = node.static_cpath
          end
        end
      end

      def precompute_meta_nodes(nodes)
        @meta_node_map = {}
        nodes.body.traverse do |event, node|
          next unless event == :enter
          case node
          when TypeProf::Core::AST::AttrReaderMetaNode
            @meta_node_map[AstUtils.location_key(node)] = { type: :attr_reader, args: node.args }
          when TypeProf::Core::AST::AttrAccessorMetaNode
            @meta_node_map[AstUtils.location_key(node)] = { type: :attr_accessor, args: node.args }
          when TypeProf::Core::AST::IncludeMetaNode
            @meta_node_map[AstUtils.location_key(node)] = { type: :include, args: node.args }
          end
        end
      end

      def collect_syntax_data(prism_ast)
        data = {}
        traverse_prism(prism_ast, data)
        data
      end

      def count_cpath_segments(node)
        case node
        when Prism::ConstantPathNode
          1 + (node.parent ? count_cpath_segments(node.parent) : 1)
        else
          1
        end
      end

      def traverse_prism(node, data)
        loc = node.location
        key = [loc.start_line, loc.start_column]
        case node
        when Prism::DefNode
          data[key] = { self_receiver: node.receiver.is_a?(Prism::SelfNode) }
        when Prism::ArrayNode
          data[key] = { opening: node.opening }
        when Prism::RangeNode
          data[key] = { exclude_end: node.exclude_end? }
        when Prism::RegularExpressionNode
          data[key] = { content: node.content, flags: node.closing.delete("/") }
        when Prism::InterpolatedRegularExpressionNode
          data[key] = { flags: node.closing.delete("/") }
        when Prism::ForNode
          idx = node.index
          if idx.is_a?(Prism::LocalVariableTargetNode)
            data[key] = { index_name: idx.name }
          else
            data[key] = { index_slice: idx.slice }
          end
        when Prism::DefinedNode
          data[key] = { value_slice: node.value.slice }
        when Prism::ConstantPathWriteNode
          data[key] = { cpath_write_segments: count_cpath_segments(node.target) }
        when Prism::RationalNode, Prism::ImaginaryNode, Prism::LambdaNode,
             Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode,
             Prism::FlipFlopNode, Prism::AliasGlobalVariableNode,
             Prism::BackReferenceReadNode
          data[key] = { slice: node.slice }
        end
        node.compact_child_nodes.each { |child| traverse_prism(child, data) }
      end
    end
  end
end
