# frozen_string_literal: true

module RubyMinify
  DYNAMIC_IVAR_METHODS = %i[
    instance_variable_get instance_variable_set
    instance_variable_defined? remove_instance_variable
    instance_variables
  ].freeze

  ATTR_DECLARATION_METHODS = %i[attr attr_reader attr_writer attr_accessor].freeze

  IVAR_WRITE_NODES = [
    Prism::InstanceVariableWriteNode,
    Prism::InstanceVariableTargetNode,
    Prism::InstanceVariableOperatorWriteNode,
    Prism::InstanceVariableOrWriteNode,
    Prism::InstanceVariableAndWriteNode
  ].freeze

  def collect_ivar_definitions(prism_root, attr_backed)
    Nesting.each(prism_root) do |node, cpath, _singleton, _in_def|
      case node
      when Prism::InstanceVariableReadNode
        next if attr_backed[cpath]&.include?(node.name)
        @ivar_rename_mapping.add_read_site(cpath, node.name, node)
      when *IVAR_WRITE_NODES
        next if attr_backed[cpath]&.include?(node.name)
        @ivar_rename_mapping.add_write_site(cpath, node.name, node)
      end
    end
  end

  def collect_attr_backed_ivars(prism_root)
    result = Hash.new { |h, k| h[k] = Set.new }
    each_attr_declaration(prism_root, ATTR_DECLARATION_METHODS, require_class_body: false) do |_node, cpath, _singleton, sym|
      result[cpath] << :"@#{sym}"
    end
    result
  end

  def scan_dynamic_ivar_access(prism_root)
    Nesting.each(prism_root) do |node, cpath, _singleton, _in_def|
      next unless node.is_a?(Prism::CallNode)
      next unless DYNAMIC_IVAR_METHODS.include?(node.name)

      recv = node.receiver
      if recv.nil? || recv.is_a?(Prism::SelfNode)
        @ivar_rename_mapping.exclude_cpath(cpath)
      end
    end
  end

  def merge_inherited_ivars
    cpaths = []
    @ivar_rename_mapping.each_canonical_cpath { |c| cpaths << c }
    cpaths.each do |cpath|
      @oracle.each_ancestor_cpath(cpath, false) do |ancestor_cpath|
        next if ancestor_cpath == cpath
        @ivar_rename_mapping.merge_with_ancestor(cpath, ancestor_cpath)
      end
    end
  end

  def reserve_attr_ivar_names(prism_root)
    each_attr_declaration(prism_root, %i[attr_reader attr_accessor]) do |_node, cpath, singleton, sym|
      getter_short = @method_rename_mapping.short_name_for_key([cpath, singleton, sym].freeze)
      next unless getter_short
      @ivar_rename_mapping.reserve_name(cpath, "@#{getter_short}")
    end
  end

  def coordinate_attr_renames(prism_root, rename_map, attr_ivar_entries)
    attr_rename_map = {}

    # ============================================
    # Phase 1: Reverse propagation (dest→src)
    # Determine short names. NO application here.
    # ============================================

    # 1a: Classify each attr as Path A (method-driven) or Path B (ivar-driven)
    path_a_info = []
    path_b_info = []

    each_attr_declaration(prism_root, %i[attr_reader attr_accessor]) do |node, cpath, singleton, sym|
      getter_key = [cpath, singleton, sym].freeze
      getter_short = @method_rename_mapping.short_name_for_key(getter_key)
      info = {
        cpath: cpath, singleton: singleton, mid: sym,
        accessor: node.name == :attr_accessor,
        loc_key: AstUtils.location_key(node),
        ivar_key: [cpath, :"@#{sym}"]
      }
      if getter_short
        info[:getter_short] = getter_short
        path_a_info << info
      else
        path_b_info << info
      end
    end

    return attr_rename_map unless path_a_info.any? || path_b_info.any?

    # 1b: Build Path A mapping
    path_a_mapping = {}
    path_a_info.each do |info|
      path_a_mapping[info[:ivar_key]] = "@#{info[:getter_short]}"
    end

    # 1c: Collect ivar nodes from AST (for both Path A apply + Path B counting)
    ivar_nodes_by_key = Hash.new { |h, k| h[k] = [] }

    Nesting.each(prism_root) do |node, cpath, _singleton, _in_def|
      case node
      when Prism::InstanceVariableReadNode, *IVAR_WRITE_NODES
        ivar_nodes_by_key[[cpath, node.name]] << node
      end
    end

    # 1d: Path B — assign ivar-driven short names
    path_b_mapping = {}
    path_b_method_mapping = {}

    if path_b_info.any?
      used_ivar_names = @ivar_rename_mapping.node_mapping.values.to_set
      used_ivar_names.merge(path_a_mapping.values)
      used_method_names = rename_map.values.to_set

      generator = NameGenerator.new([], prefix: "@")

      path_b_info
        .sort_by do |info|
          ivar_name = info[:ivar_key][1]
          count = ivar_nodes_by_key[info[:ivar_key]].size
          -(ivar_name.to_s.length * count)
        end
        .each do |info|
          ivar_key = info[:ivar_key]
          ivar_name = ivar_key[1]
          ivar_count = ivar_nodes_by_key[ivar_key].size
          next if ivar_count == 0
          next if ivar_name.to_s.length <= 2

          short_name = nil
          method_short = nil
          loop do
            candidate = generator.next_name
            method_candidate = candidate.delete_prefix("@").to_sym

            next if used_ivar_names.include?(candidate)
            next if used_method_names.include?(method_candidate.to_s)
            next if @oracle.method_defined?(info[:cpath], info[:singleton], method_candidate)

            short_name = candidate
            method_short = method_candidate
            break
          end

          getter_calls = @oracle.method_call_count(info[:cpath], info[:singleton], info[:mid])
          setter_calls = 0
          if info[:accessor]
            setter_calls = @oracle.method_call_count(info[:cpath], info[:singleton], :"#{info[:mid]}=")
          end

          ivar_savings = (ivar_name.to_s.length - short_name.length) * ivar_count
          method_savings = (info[:mid].to_s.length - method_short.to_s.length) * (getter_calls + setter_calls + 1)
          total_savings = ivar_savings + method_savings
          next unless total_savings > 0

          used_ivar_names << short_name
          used_method_names << method_short.to_s

          path_b_mapping[ivar_key] = short_name
          path_b_method_mapping[ivar_key] = method_short
        end
    end

    # ============================================
    # Phase 2: Application (src→all dests)
    # Apply final short names after all propagation.
    # ============================================

    combined_mapping = path_a_mapping.merge(path_b_mapping)

    # 2a: attr declaration renames → attr_rename_map
    path_a_info.each do |info|
      renames = attr_rename_map[info[:loc_key]] || {}
      renames[info[:mid]] = info[:getter_short]
      attr_rename_map[info[:loc_key]] = renames
    end

    path_b_info.each do |info|
      method_short = path_b_method_mapping[info[:ivar_key]]
      next unless method_short
      renames = attr_rename_map[info[:loc_key]] || {}
      renames[info[:mid]] = method_short
      attr_rename_map[info[:loc_key]] = renames
    end

    # 2b: ivar read/write renames → attr_ivar_entries
    ivar_nodes_by_key.each do |(cpath, ivar_name), nodes_list|
      short = combined_mapping[[cpath, ivar_name]]
      unless short
        @oracle.each_ancestor_cpath(cpath, false) do |ancestor_cpath|
          next if ancestor_cpath == cpath
          short = combined_mapping[[ancestor_cpath, ivar_name]]
          break if short
        end
      end
      next unless short
      nodes_list.each { |n| attr_ivar_entries[AstUtils.location_key(n)] = short }
    end

    # 2c: setter call site renames → rename_map (Path A)
    path_a_info.each do |info|
      next unless info[:accessor]
      @oracle.each_call_site_key(info[:cpath], info[:singleton], :"#{info[:mid]}=") do |key|
        rename_map[key] = "#{info[:getter_short]}="
      end
    end

    # 2d: getter + setter call site renames → rename_map (Path B)
    path_b_info.each do |info|
      method_short = path_b_method_mapping[info[:ivar_key]]
      next unless method_short

      @oracle.each_call_site_key(info[:cpath], info[:singleton], info[:mid]) do |key|
        rename_map[key] = method_short.to_s
      end

      next unless info[:accessor]
      @oracle.each_call_site_key(info[:cpath], info[:singleton], :"#{info[:mid]}=") do |key|
        rename_map[key] = "#{method_short}="
      end
    end

    attr_rename_map
  end

  private

  # attr declarations with meta semantics: a bare `attr_*` in a class or
  # module body. With require_class_body: false, ones inside method bodies
  # count too — the attr-backed scan wants those as well, since the methods
  # they define still read the ivar.
  def each_attr_declaration(prism_root, methods, require_class_body: true)
    Nesting.each(prism_root) do |node, cpath, singleton, in_def|
      next unless node.is_a?(Prism::CallNode)
      next unless methods.include?(node.name)
      next unless node.receiver.nil?
      next if require_class_body && in_def

      node.arguments&.arguments&.each do |arg|
        next unless arg.is_a?(Prism::SymbolNode)
        yield node, cpath, singleton, arg.unescaped.to_sym
      end
    end
  end
end
