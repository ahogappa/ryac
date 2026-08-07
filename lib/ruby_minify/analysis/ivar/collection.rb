# frozen_string_literal: true

module RubyMinify
  DYNAMIC_IVAR_METHODS = %i[
    instance_variable_get instance_variable_set
    instance_variable_defined? remove_instance_variable
    instance_variables
  ].freeze

  def collect_ivar_definitions(nodes, attr_backed)
    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::InstanceVariableReadNode
        cpath = node.lenv.cref.cpath
        next if attr_backed[cpath]&.include?(node.var)
        @ivar_rename_mapping.add_read_site(cpath, node.var, node)
      when TypeProf::Core::AST::InstanceVariableWriteNode
        cpath = node.lenv.cref.cpath
        next if attr_backed[cpath]&.include?(node.var)
        @ivar_rename_mapping.add_write_site(cpath, node.var, node)
      when TypeProf::Core::AST::DefinedNode
        raw = node.instance_variable_get(:@raw_node)
        next unless raw.is_a?(Prism::DefinedNode) && raw.value.is_a?(Prism::InstanceVariableReadNode)
        ivar_node = raw.value
        cpath = node.lenv.cref.cpath
        next if attr_backed[cpath]&.include?(ivar_node.name)
        @ivar_rename_mapping.add_read_site(cpath, ivar_node.name, ivar_node)
      end
    end
  end

  def collect_attr_backed_ivars(nodes)
    result = Hash.new { |h, k| h[k] = Set.new }
    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::AttrReaderMetaNode,
           TypeProf::Core::AST::AttrWriterMetaNode,
           TypeProf::Core::AST::AttrAccessorMetaNode
        cpath = node.lenv.cref.cpath
        node.args.each { |sym| result[cpath] << :"@#{sym}" }
      # attr_* only becomes a meta node in a class/module body with no receiver;
      # anywhere else TypeProf still reports a plain call.
      when TypeProf::Core::AST::CallNode
        next unless %i[attr attr_reader attr_writer attr_accessor].include?(node.mid)
        next unless node.recv.nil?
        cpath = node.lenv.cref.cpath
        node.positional_args&.each do |arg|
          next unless arg.is_a?(TypeProf::Core::AST::SymbolNode)
          result[cpath] << :"@#{arg.lit}"
        end
      end
    end
    result
  end

  def scan_dynamic_ivar_access(nodes)
    nodes.traverse do |event, node|
      next unless event == :enter
      next unless node.is_a?(TypeProf::Core::AST::CallNode)
      next unless DYNAMIC_IVAR_METHODS.include?(node.mid)

      recv = node.recv
      if recv.nil? || recv.is_a?(TypeProf::Core::AST::SelfNode)
        cpath = node.lenv.cref.cpath
        @ivar_rename_mapping.exclude_cpath(cpath)
      end
    end
  end

  def merge_inherited_ivars(genv)
    cpaths = []
    @ivar_rename_mapping.each_canonical_cpath { |c| cpaths << c }
    cpaths.each do |cpath|
      mod = genv.resolve_cpath(cpath) rescue nil
      next unless mod
      genv.each_superclass(mod, false) do |ancestor_mod, _|
        next if ancestor_mod.cpath == cpath
        @ivar_rename_mapping.merge_with_ancestor(cpath, ancestor_mod.cpath)
      end
    end
  end

  def reserve_attr_ivar_names(nodes)
    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::AttrReaderMetaNode,
           TypeProf::Core::AST::AttrAccessorMetaNode
        node.boxes(:mdef) do |box|
          next if box.mid.to_s.end_with?('=')
          getter_key = [box.cpath, box.singleton, box.mid].freeze
          getter_short = @method_rename_mapping.short_name_for_key(getter_key)
          next unless getter_short
          @ivar_rename_mapping.reserve_name(box.cpath, "@#{getter_short}")
        end
      end
    end
  end

  def coordinate_attr_renames(nodes, genv, rename_map, attr_ivar_entries)
    attr_rename_map = {}

    # ============================================
    # Phase 1: Reverse propagation (dest→src)
    # Determine short names. NO application here.
    # ============================================

    # 1a: Classify each attr as Path A (method-driven) or Path B (ivar-driven)
    path_a_info = []
    path_b_info = []

    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::AttrReaderMetaNode,
           TypeProf::Core::AST::AttrAccessorMetaNode
        node.boxes(:mdef) do |box|
          next if box.mid.to_s.end_with?('=')
          getter_key = [box.cpath, box.singleton, box.mid].freeze
          getter_short = @method_rename_mapping.short_name_for_key(getter_key)
          ivar_key = [box.cpath, :"@#{box.mid}"]
          info = { box: box, node: node, loc_key: AstUtils.location_key(node), ivar_key: ivar_key }
          if getter_short
            info[:getter_short] = getter_short
            path_a_info << info
          else
            path_b_info << info
          end
        end
      end
    end

    return attr_rename_map if path_a_info.empty? && path_b_info.empty?

    # 1b: Build Path A mapping
    path_a_mapping = {}
    path_a_info.each do |info|
      path_a_mapping[info[:ivar_key]] = "@#{info[:getter_short]}"
    end

    # 1c: Collect ivar nodes from AST (for both Path A apply + Path B counting)
    ivar_nodes_by_key = Hash.new { |h, k| h[k] = [] }

    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::InstanceVariableReadNode,
           TypeProf::Core::AST::InstanceVariableWriteNode
        cpath = node.lenv.cref.cpath
        ivar_nodes_by_key[[cpath, node.var]] << node
      when TypeProf::Core::AST::DefinedNode
        raw = node.instance_variable_get(:@raw_node)
        next unless raw.is_a?(Prism::DefinedNode) && raw.value.is_a?(Prism::InstanceVariableReadNode)
        cpath = node.lenv.cref.cpath
        ivar_nodes_by_key[[cpath, raw.value.name]] << raw.value
      end
    end

    # 1d: Path B — assign ivar-driven short names
    path_b_mapping = {}
    path_b_method_mapping = {}

    unless path_b_info.empty?
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
          box = info[:box]
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

            existing = genv.resolve_method(box.cpath, box.singleton, method_candidate) rescue nil
            next if existing && existing.defs.size > 0

            short_name = candidate
            method_short = method_candidate
            break
          end

          getter_method = genv.resolve_method(box.cpath, box.singleton, box.mid) rescue nil
          getter_calls = getter_method ? getter_method.method_call_boxes.size : 0
          setter_calls = 0
          if info[:node].is_a?(TypeProf::Core::AST::AttrAccessorMetaNode)
            setter_mid = :"#{box.mid}="
            setter_method = genv.resolve_method(box.cpath, box.singleton, setter_mid) rescue nil
            setter_calls = setter_method ? setter_method.method_call_boxes.size : 0
          end

          ivar_savings = (ivar_name.to_s.length - short_name.length) * ivar_count
          method_savings = (box.mid.to_s.length - method_short.to_s.length) * (getter_calls + setter_calls + 1)
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
      renames[info[:box].mid] = info[:getter_short]
      attr_rename_map[info[:loc_key]] = renames
    end

    path_b_info.each do |info|
      method_short = path_b_method_mapping[info[:ivar_key]]
      next unless method_short
      renames = attr_rename_map[info[:loc_key]] || {}
      renames[info[:box].mid] = method_short
      attr_rename_map[info[:loc_key]] = renames
    end

    # 2b: ivar read/write renames → attr_ivar_entries
    ivar_nodes_by_key.each do |(cpath, ivar_name), nodes_list|
      short = combined_mapping[[cpath, ivar_name]]
      unless short
        mod = genv.resolve_cpath(cpath) rescue nil
        if mod
          genv.each_superclass(mod, false) do |ancestor_mod, _|
            next if ancestor_mod.cpath == cpath
            short = combined_mapping[[ancestor_mod.cpath, ivar_name]]
            break if short
          end
        end
      end
      next unless short
      nodes_list.each { |n| attr_ivar_entries[AstUtils.location_key(n)] = short }
    end

    # 2c: setter call site renames → rename_map (Path A)
    path_a_info.each do |info|
      next unless info[:node].is_a?(TypeProf::Core::AST::AttrAccessorMetaNode)
      box = info[:box]
      setter_mid = :"#{box.mid}="
      setter_method = genv.resolve_method(box.cpath, box.singleton, setter_mid) rescue nil
      next unless setter_method
      setter_method.method_call_boxes.each do |cb|
        rename_map[AstUtils.location_key(cb.node)] = "#{info[:getter_short]}="
      end
    end

    # 2d: getter + setter call site renames → rename_map (Path B)
    path_b_info.each do |info|
      method_short = path_b_method_mapping[info[:ivar_key]]
      next unless method_short

      box = info[:box]
      getter_method = genv.resolve_method(box.cpath, box.singleton, box.mid) rescue nil
      if getter_method
        getter_method.method_call_boxes.each do |cb|
          rename_map[AstUtils.location_key(cb.node)] = method_short.to_s
        end
      end

      next unless info[:node].is_a?(TypeProf::Core::AST::AttrAccessorMetaNode)
      setter_mid = :"#{box.mid}="
      setter_method = genv.resolve_method(box.cpath, box.singleton, setter_mid) rescue nil
      next unless setter_method
      setter_method.method_call_boxes.each do |cb|
        rename_map[AstUtils.location_key(cb.node)] = "#{method_short}="
      end
    end

    attr_rename_map
  end
end
