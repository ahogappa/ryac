# frozen_string_literal: true

module Ryac
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
        # @type var node: Prism::InstanceVariableWriteNode | Prism::InstanceVariableTargetNode | Prism::InstanceVariableOperatorWriteNode | Prism::InstanceVariableOrWriteNode | Prism::InstanceVariableAndWriteNode
        next if attr_backed[cpath]&.include?(node.name)
        @ivar_rename_mapping.add_write_site(cpath, node.name, node)
      end
    end
  end

  def collect_attr_backed_ivars(prism_root)
    result = Hash.new { |h, k| h[k] = Set.new } #: Hash[Array[Symbol], Set[Symbol]]
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
    cpaths = [] #: Array[Array[Symbol]]
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

  # attr declarations rename along two paths. Path A (method-driven): the
  # getter already got a short name from method renaming, and the backing
  # ivar follows it. Path B (ivar-driven): the getter wasn't renamed, so a
  # name is chosen from the ivar side and the getter (and setter) follow.
  # Phase 1 decides every name, phase 2 applies them — declaration, ivar
  # sites, and accessor call sites — only once all decisions are in.
  def coordinate_attr_renames(prism_root, rename_map, attr_ivar_entries)
    path_a_info, path_b_info = classify_attr_declarations(prism_root)
    return {} unless path_a_info.any? || path_b_info.any?

    path_a_mapping = path_a_info.to_h { |info| [info[:ivar_key], "@#{info[:getter_short]}"] }
    ivar_nodes_by_key = collect_ivar_nodes_by_key(prism_root)
    path_b_mapping, path_b_method_mapping =
      assign_ivar_driven_names(path_b_info, ivar_nodes_by_key, path_a_mapping, rename_map)

    apply_ivar_renames(ivar_nodes_by_key, path_a_mapping.merge(path_b_mapping), attr_ivar_entries)
    apply_accessor_call_renames(path_a_info, path_b_info, path_b_method_mapping, rename_map)
    build_attr_rename_map(path_a_info, path_b_info, path_b_method_mapping)
  end

  private

  def classify_attr_declarations(prism_root)
    path_a_info = [] #: Array[attr_info]
    path_b_info = [] #: Array[attr_info]
    each_attr_declaration(prism_root, %i[attr_reader attr_accessor]) do |node, cpath, singleton, sym|
      method_key = [cpath, singleton, sym].freeze
      getter_short = @method_rename_mapping.short_name_for_key(method_key)
      info = {
        cpath: cpath, singleton: singleton, mid: sym,
        accessor: node.name == :attr_accessor,
        loc_key: AstUtils.location_key(node),
        ivar_key: [cpath, :"@#{sym}"],
        method_key: method_key
      }
      if getter_short
        info[:getter_short] = getter_short
        path_a_info << info
      elsif @method_rename_mapping.has_method?(method_key) &&
            @method_rename_mapping.group_keys(method_key) == [method_key]
        # An excluded mid (dynamic dispatch, unresolved call, hidden attr
        # write, ...) was left alone for a reason — the ivar side must not
        # rename it either. A group spanning other keys means the mid's
        # sites are shared with defs this declaration does not cover.
        path_b_info << info
      end
    end
    [path_a_info, path_b_info]
  end

  def collect_ivar_nodes_by_key(prism_root)
    ivar_nodes_by_key = Hash.new { |h, k| h[k] = [] } #: Hash[[Array[Symbol], Symbol], Array[Prism::Node]]
    Nesting.each(prism_root) do |node, cpath, _singleton, _in_def|
      case node
      when Prism::InstanceVariableReadNode, *IVAR_WRITE_NODES
        # @type var node: Prism::InstanceVariableReadNode | Prism::InstanceVariableWriteNode | Prism::InstanceVariableTargetNode | Prism::InstanceVariableOperatorWriteNode | Prism::InstanceVariableOrWriteNode | Prism::InstanceVariableAndWriteNode
        ivar_nodes_by_key[[cpath, node.name]] << node
      end
    end
    ivar_nodes_by_key
  end

  # Path B: pick a fresh @name whose bare form is free as a method name too,
  # then keep it only when renaming ivar sites plus accessor calls saves
  # more than it costs.
  def assign_ivar_driven_names(path_b_info, ivar_nodes_by_key, path_a_mapping, rename_map)
    path_b_mapping = {} #: Hash[[Array[Symbol], Symbol], String]
    path_b_method_mapping = {} #: Hash[[Array[Symbol], Symbol], Symbol]
    return [path_b_mapping, path_b_method_mapping] if path_b_info.none?

    used_ivar_names = @ivar_rename_mapping.node_mapping.values.to_set
    used_ivar_names.merge(path_a_mapping.values)
    used_method_names = rename_map.values.to_set
    scope_vars = MethodRenameMapping.build_scope_vars(@scope_mappings)
    generator = NameGenerator.new([], prefix: "@")

    path_b_info
      .sort_by do |info|
        ivar_name = info[:ivar_key][1]
        count = ivar_nodes_by_key[info[:ivar_key]].size
        -(ivar_name.to_s.size * count)
      end
      .each do |info|
        ivar_key = info[:ivar_key]
        ivar_name = ivar_key[1]
        ivar_count = ivar_nodes_by_key[ivar_key].size
        next if ivar_count == 0
        next if ivar_name.to_s.size <= 2

        getter_calls = 0
        implicit_scope_ids = [] #: Array[scope_id]
        @method_rename_mapping.each_group_call_site(info[:method_key]) do |_site, scope_id|
          getter_calls += 1
          implicit_scope_ids << scope_id if scope_id
        end

        short_name = nil
        method_short = nil
        loop do
          candidate = generator.next_name
          method_candidate = candidate.delete_prefix("@").to_sym

          next if used_ivar_names.include?(candidate)
          next if used_method_names.include?(method_candidate.to_s)
          next if @oracle.method_defined?(info[:cpath], info[:singleton], method_candidate)
          # A bare renamed getter call would parse as the local if a visible
          # local already owns the candidate at an implicit-receiver site.
          next if implicit_scope_ids.any? { |sid| scope_vars[sid].include?(method_candidate.to_s) }

          short_name = candidate
          method_short = method_candidate
          break
        end

        setter_calls = 0
        if info[:accessor]
          setter_calls = @oracle.method_call_count(info[:cpath], info[:singleton], :"#{info[:mid]}=")
        end

        # the loop above always breaks with short_name/method_short assigned
        ivar_savings = (ivar_name.to_s.size - short_name.size) * ivar_count # steep:ignore NoMethod
        method_savings = (info[:mid].to_s.size - method_short.to_s.size) * (getter_calls + setter_calls + 1)
        next unless ivar_savings + method_savings > 0

        used_ivar_names << short_name
        used_method_names << method_short.to_s

        path_b_mapping[ivar_key] = short_name # steep:ignore ArgumentTypeMismatch
        path_b_method_mapping[ivar_key] = method_short # steep:ignore ArgumentTypeMismatch
      end

    [path_b_mapping, path_b_method_mapping]
  end


  # Ivar read/write sites take their attr's name; a subclass's sites follow
  # the ancestor that declared the attr.
  def apply_ivar_renames(ivar_nodes_by_key, combined_mapping, attr_ivar_entries)
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
  end

  def apply_accessor_call_renames(path_a_info, path_b_info, path_b_method_mapping, rename_map)
    path_a_info.each do |info|
      next unless info[:accessor]
      @oracle.each_call_site_key(info[:cpath], info[:singleton], :"#{info[:mid]}=") do |key|
        rename_map[key] = "#{info[:getter_short]}="
      end
    end

    path_b_info.each do |info|
      method_short = path_b_method_mapping[info[:ivar_key]]
      next unless method_short

      # The mapping's group sites, not the oracle's: sites attached by the
      # unresolved-call pass exist only in the mapping, and missing one here
      # would leave it calling the old name.
      @method_rename_mapping.each_group_call_site(info[:method_key]) do |site, _scope_id|
        rename_map[AstUtils.location_key(site)] = method_short.to_s
      end

      next unless info[:accessor]
      @oracle.each_call_site_key(info[:cpath], info[:singleton], :"#{info[:mid]}=") do |key|
        rename_map[key] = "#{method_short}="
      end
    end
  end

  def build_attr_rename_map(path_a_info, path_b_info, path_b_method_mapping)
    # Values are the getter shorts: path A stores Strings, path B Symbols;
    # consumers interpolate, so both work.
    attr_rename_map = {} #: Hash[location_key, Hash[Symbol, untyped]]
    path_a_info.each do |info|
      (attr_rename_map[info[:loc_key]] ||= {})[info[:mid]] = info[:getter_short]
    end
    path_b_info.each do |info|
      method_short = path_b_method_mapping[info[:ivar_key]]
      next unless method_short
      (attr_rename_map[info[:loc_key]] ||= {})[info[:mid]] = method_short
    end
    attr_rename_map
  end

  # attr declarations with meta semantics, one yield per symbol argument.
  # With require_class_body: false, bare attr_* calls anywhere count — the
  # attr-backed scan wants those too, since the methods they define still
  # read the ivar.
  def each_attr_declaration(prism_root, methods, require_class_body: true)
    Nesting.each_meta_call(prism_root, methods, loose: !require_class_body) do |node, cpath, singleton|
      AstUtils.symbol_arguments(node).each do |sym|
        yield node, cpath, singleton, sym
      end
    end
  end
end
