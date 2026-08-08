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

        analyze_keywords_and_scopes(nodes, genv)
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

      def analyze_keywords_and_scopes(nodes, genv)
        @keyword_rename_mapping = KeywordRenameMapping.new
        collect_keyword_info(nodes, genv)
        @keyword_rename_mapping.assign_short_names

        @keyword_def_node_map = @keyword_rename_mapping.def_node_mapping(@keyword_def_node_registry || {})
        @keyword_variable_hints = @keyword_rename_mapping.build_variable_hints

        @scope_mappings = {}
        build_scope_mappings(nodes, @scope_mappings, kw_def_map: @keyword_def_node_map, var_hints_map: @keyword_variable_hints)
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

      def precompute_rename_entries(nodes)
        local_rename_entries = precompute_variable_names(nodes, @scope_mappings)
        precompute_lambda_variable_names(nodes, @scope_mappings, local_rename_entries)
        augment_def_node_params(nodes, @scope_mappings, :param_names)
        @block_param_names_map = precompute_block_params(nodes, @scope_mappings, local_rename_entries)
        augment_for_index(nodes, @scope_mappings, :for_index_mangled)
        local_rename_entries
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

      def precompute_variable_names(nodes, scope_mappings)
        map = {}
        nodes.traverse do |event, node|
          next unless event == :enter
          case node
          when TypeProf::Core::AST::LocalVariableReadNode,
               TypeProf::Core::AST::LocalVariableWriteNode
            map[AstUtils.location_key(node)] = get_mangled_name(node, node.var, scope_mappings)
          when TypeProf::Core::AST::DefNode
            raw = AstUtils.prism_node(node)
            next unless raw.receiver.is_a?(Prism::LocalVariableReadNode)
            map[AstUtils.location_key(raw.receiver)] = get_mangled_name(node, raw.receiver.name, scope_mappings)
          when TypeProf::Core::AST::DefinedNode
            raw = AstUtils.prism_node(node)
            next unless raw.is_a?(Prism::DefinedNode) && raw.value.is_a?(Prism::LocalVariableReadNode)
            lvar_node = raw.value
            map[AstUtils.location_key(lvar_node)] = get_mangled_name(node, lvar_node.name, scope_mappings)
          end
        end
        map
      end

      def precompute_lambda_variable_names(nodes, scope_mappings, variable_rename_entries)
        nodes.traverse do |event, node|
          next unless event == :enter
          next unless node.is_a?(TypeProf::Core::AST::LambdaNode)
          raw = AstUtils.prism_node(node)
          next unless raw.is_a?(Prism::LambdaNode) && raw.body
          cref = node.lenv&.cref
          next unless cref
          walk_prism_tree(raw.body) do |pnode|
            case pnode
            when Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode
              next if pnode.depth == 0
              mangled = find_scope_var_name(cref, pnode.name, scope_mappings)
              variable_rename_entries[AstUtils.location_key(pnode)] = mangled if mangled
            end
          end
        end
      end

      def find_scope_var_name(cref, var_name, scope_mappings)
        current = cref
        while current
          mapping = scope_mappings[current.object_id]
          return mapping[var_name] if mapping&.key?(var_name)
          current = current.outer
        end
        nil
      end

      def walk_prism_tree(node, &block)
        return unless node
        yield node
        node.compact_child_nodes.each { |child| walk_prism_tree(child, &block) }
      end

      def block_has_non_required_params?(params)
        params && (
          params.optionals&.any? ||
          params.rest ||
          params.posts&.any? ||
          params.keywords&.any? ||
          params.keyword_rest ||
          params.block
        )
      end

      def collect_block_body_var_keys(body_node, var_name)
        keys = []
        walk_prism_tree(body_node) do |n|
          case n
          when Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode,
               Prism::LocalVariableTargetNode
            keys << AstUtils.location_key(n) if n.name == var_name
          end
        end
        keys
      end

      def augment_def_node_params(nodes, scope_mappings, syntax_key)
        nodes.traverse do |event, node|
          next unless event == :enter
          next unless node.is_a?(TypeProf::Core::AST::DefNode)

          body_node = node.body
          body_node = nil if body_node.is_a?(TypeProf::Core::AST::DummyNilNode)

          param_names = {}
          all_params = node.req_positionals + node.opt_positionals + node.post_positionals +
            (node.req_keywords || []) + (node.opt_keywords || [])
          all_params << node.rest_positionals if node.rest_positionals
          all_params << node.rest_keywords if node.rest_keywords
          all_params << node.block if node.block
          all_params.each do |p|
            param_names[p] = body_node ? get_mangled_name(body_node, p, scope_mappings) : p.to_s
          end

          raw = AstUtils.prism_node(node)
          loc = raw.location
          key = [loc.start_line, loc.start_column]
          @syntax_data[key] = {} unless @syntax_data[key]
          @syntax_data[key][syntax_key] = param_names
        end
      end

      def precompute_block_params(nodes, scope_mappings, local_rename_entries = {})
        block_param_names_map = {}
        nodes.traverse do |event, node|
          next unless event == :enter
          next unless node.is_a?(TypeProf::Core::AST::CallNode)
          raw = AstUtils.prism_node(node)
          has_block_params = node.block_f_args&.any? ||
            (raw.block.is_a?(Prism::BlockNode) &&
             raw.block.parameters.is_a?(Prism::BlockParametersNode) &&
             raw.block.parameters.parameters &&
             collect_extra_block_param_names(raw.block.parameters.parameters).any?)
          next unless has_block_params

          block_body_node = node.block_body
          block_body_node = nil if block_body_node.is_a?(TypeProf::Core::AST::DummyNilNode)

          block_param_names = {}
          node.block_f_args&.each do |param|
            next unless param
            block_param_names[param] = block_body_node ? get_mangled_name(block_body_node, param, scope_mappings) : param.to_s
          end
          node.block_multi_targets&.each_value do |mt|
            collect_multi_target_names(mt).each do |name|
              block_param_names[name] = block_body_node ? get_mangled_name(block_body_node, name, scope_mappings) : name.to_s
            end
          end
          # Add non-required block params from Prism AST
          if raw.block.is_a?(Prism::BlockNode) &&
             raw.block.parameters.is_a?(Prism::BlockParametersNode) &&
             raw.block.parameters.parameters
            collect_extra_block_param_names(raw.block.parameters.parameters).each do |name|
              next if block_param_names.key?(name)
              block_param_names[name] = block_body_node ? get_mangled_name(block_body_node, name, scope_mappings) : name.to_s
            end
          end

          # Numbered parameters (_1, _2) only work for blocks with simple required
          # params. If the block has optionals, rest, keywords, or block params,
          # we must fall back to regular short names.
          if raw.block.is_a?(Prism::BlockNode) &&
             raw.block.parameters.is_a?(Prism::BlockParametersNode) &&
             block_has_non_required_params?(raw.block.parameters.parameters)
            numbered_params = block_param_names.select { |_, v| v.match?(/\A_\d+\z/) }
            if numbered_params.any?
              gen = NameGenerator.new(block_param_names.values.reject { |v| v.match?(/\A_\d+\z/) })
              numbered_params.each do |param_name, old_mangled|
                new_name = gen.next_name
                block_param_names[param_name] = new_name
                # Update local_rename_entries only for variables in this block body
                body_keys = collect_block_body_var_keys(raw.block.body, param_name)
                body_keys.each { |k| local_rename_entries[k] = new_name if local_rename_entries[k] == old_mangled }
              end
            end
          end

          block_param_names_map[AstUtils.location_key(node)] = block_param_names
        end
        block_param_names_map
      end

      def augment_for_index(nodes, scope_mappings, syntax_key)
        nodes.traverse do |event, node|
          next unless event == :enter
          next unless node.is_a?(TypeProf::Core::AST::ForNode)

          raw = AstUtils.prism_node(node)
          loc = raw.location
          key = [loc.start_line, loc.start_column]
          data = @syntax_data[key]
          next unless data&.[](:index_name)

          if node.body
            data[syntax_key] = begin
              get_mangled_name(node.body, data[:index_name], scope_mappings)
            rescue
              data[:index_name].to_s
            end
          end
        end
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
