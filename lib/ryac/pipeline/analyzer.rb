# frozen_string_literal: true

require 'stringio'

module Ryac
  module Pipeline
    # Stage 3: Analysis
    # Parses source with TypeProf, builds scope mappings,
    # collects constants and their references, and freezes mappings.
    class Analyzer < Stage
      include Ryac

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
        @prism_root = prism_result.value
        @oracle = TypeOracle.new(genv, nodes)
        @boot_constant_roots = boot_constant_roots(source.stdlib_requires)
        @syntax_data = collect_syntax_data(@prism_root)

        analyze_keywords_and_scopes
        analyze_methods_phase
        method_alias_map, method_transform_map = resolve_method_aliases_and_transforms(@prism_root)
        analyze_variables_phase

        rename_map = @method_rename_mapping.node_mapping.dup
        attr_ivar_entries = {} #: Hash[location_key, String]
        attr_rename_map = coordinate_attr_renames(@prism_root, rename_map, attr_ivar_entries)

        analyze_constants_phase
        local_rename_entries = precompute_rename_entries
        precompute_constant_resolution
        precompute_meta_nodes

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
        begin
          service.update_rb_file(path, content)
        rescue NoMethodError => e
          construct = unsupported_construct(prism_result.value)
          where = construct ? "#{construct[:label]} (#{path}:#{construct[:line]})" : 'this source'
          raise MinifyError,
                "type analysis cannot ingest #{where}: typeprof #{TypeProf::VERSION} " \
                "crashed converting it (#{e.message.lines[0].strip}); a newer typeprof may support it"
        end
        nodes = service.instance_variable_get(:@rb_text_nodes)[path]

        [prism_result, nodes, service.genv]
      end

      # The ingestion crashes typeprof 0.32.0 is known for, so the rescue
      # above can name the construct. A typeprof carrying ruby/typeprof#465
      # and #451 ingests all of these, never reaches the rescue, and these
      # shapes simply minify — do NOT pre-emptively reject them here.
      def unsupported_construct(root)
        found = nil
        AstUtils.each_node(root) do |n|
          case n
          when Prism::FindPatternNode
            # right is SplatNode | MissingNode in Prism's types; the source
            # parsed successfully, so a missing splat cannot occur here.
            right = n.right
            if n.left.expression.nil? || !right.is_a?(Prism::SplatNode) || right.expression.nil?
              found = { label: 'find patterns with an anonymous splat (`in [*, x, *]`)',
                        line: n.location.start_line }
            end
          when Prism::HashPatternNode
            if n.rest.is_a?(Prism::NoKeywordsParameterNode)
              found = { label: '`**nil` hash patterns', line: n.location.start_line }
            end
          when Prism::BlockParametersNode
            if n.parameters.nil?
              found = { label: 'parameterless block pipes (`{ || }`, `{ |;x| }`)',
                        line: n.location.start_line }
            end
          end
          break if found
        end
        found
      end

      def analyze_keywords_and_scopes
        @local_scopes = LocalScopes.new(@prism_root)

        @keyword_rename_mapping = KeywordRenameMapping.new
        collect_keyword_info(@prism_root)
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

      def analyze_methods_phase
        @method_rename_mapping = MethodRenameMapping.new
        collect_method_definitions(@prism_root)
        resolve_method_calls
        collect_alias_undef_methods(@prism_root)
        scan_dynamic_method_references(@prism_root)
        collect_visibility_modifier_methods(@prism_root)
        collect_attr_write_exclusions(@prism_root)
        collect_shorthand_pun_methods(@prism_root)
        @method_rename_mapping.assign_short_names(@scope_mappings, @oracle)
      end

      def analyze_variables_phase
        @ivar_rename_mapping = IvarRenameMapping.new
        attr_backed = collect_attr_backed_ivars(@prism_root)
        collect_ivar_definitions(@prism_root, attr_backed)
        scan_dynamic_ivar_access(@prism_root)
        merge_inherited_ivars
        reserve_attr_ivar_names(@prism_root)
        @ivar_rename_mapping.assign_short_names

        @cvar_rename_mapping = CvarRenameMapping.new
        collect_cvar_definitions(@prism_root)
        scan_dynamic_cvar_access(@prism_root)
        merge_inherited_cvars
        @cvar_rename_mapping.assign_short_names

        @gvar_rename_mapping = GvarRenameMapping.new
        collect_gvar_definitions(@prism_root)
        scan_alias_globals(@prism_root)
        @gvar_rename_mapping.assign_short_names
      end

      def analyze_constants_phase
        @constant_mapping = ConstantRenameMapping.new(boot_roots: @boot_constant_roots)
        collect_constants(@prism_root)
        exclude_private_constants(@prism_root)
        count_constant_references(@prism_root)
        augment_constant_counts_via_oracle
        collect_external_references(@prism_root)
      end

      def precompute_rename_entries
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

      META_CALL_METHODS = %i[include attr_reader attr_accessor].freeze

      # Calls the renamer rewrites structurally instead of as plain calls.
      def precompute_meta_nodes
        @meta_node_map = {}
        Nesting.each_meta_call(@prism_root, META_CALL_METHODS) do |call_node, _cpath, _singleton|
          case call_node.name
          when :attr_reader, :attr_accessor
            next unless call_node.arguments

            @meta_node_map[AstUtils.location_key(call_node)] =
              { type: call_node.name, args: AstUtils.symbol_arguments(call_node) }
          when :include
            @meta_node_map[AstUtils.location_key(call_node)] = { type: :include }
          end
        end
      end

      def collect_syntax_data(prism_ast)
        data = {} #: syntax_data_map
        traverse_prism(prism_ast, data)
        data
      end

      def traverse_prism(node, data)
        loc = node.location
        key = [loc.start_line, loc.start_column] #: [Integer, Integer]
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
