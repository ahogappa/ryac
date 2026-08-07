# frozen_string_literal: true

module RubyMinify
  def collect_method_definitions(nodes, genv)
    nodes.traverse do |event, node|
      next unless event == :enter

      case node
      when TypeProf::Core::AST::DefNode
        node.boxes(:mdef) do |box|
          cpath = box.cpath
          # TypeProf uses the enclosing scope's cpath for def receivers,
          # not the receiver's cpath. Correct it for constant receivers.
          raw = node.instance_variable_get(:@raw_node)
          if raw&.receiver && !raw.receiver.is_a?(Prism::SelfNode)
            corrected = resolve_def_receiver_cpath(raw.receiver, genv)
            cpath = corrected if corrected
          end
          method_key = [cpath, box.singleton, box.mid].freeze
          next if EXCLUDED_METHODS.include?(box.mid)
          @method_rename_mapping.add_method(method_key, node)
          link_module_function_variant(genv, node, cpath, box.singleton, box.mid, method_key)
        end
      when TypeProf::Core::AST::AttrReaderMetaNode,
           TypeProf::Core::AST::AttrAccessorMetaNode
        node.boxes(:mdef) do |box|
          next if box.mid.to_s.end_with?('=')
          method_key = [box.cpath, box.singleton, box.mid].freeze
          next if EXCLUDED_METHODS.include?(box.mid)
          @method_rename_mapping.add_method(method_key, node)
        end
      end
    end
  end

  def resolve_method_calls(genv, nodes)
    call_node_to_keys = Hash.new { |h, k| h[k] = [] }
    resolved_call_ids = Set.new
    super_merges = []

    @method_rename_mapping.each_method_key do |key|
      method_entity = genv.resolve_method(key[0], key[1], key[2])
      next unless method_entity

      method_entity.method_call_boxes.each do |call_box|
        call_node = call_box.node

        if call_node.is_a?(TypeProf::Core::AST::SuperNode) ||
           call_node.is_a?(TypeProf::Core::AST::ForwardingSuperNode)
          child_cpath = call_node.lenv.cref.cpath
          super_merges << [[child_cpath, key[1], key[2]].freeze, key]
          next
        end

        @method_rename_mapping.add_call_site(call_node, key, has_receiver: !call_node.recv.nil?)
        call_node_to_keys[call_node.object_id] << key
        resolved_call_ids << call_node.object_id
      end
    end

    merge_super_groups(super_merges)
    merge_polymorphic_groups(call_node_to_keys)
    merge_unresolved_calls(nodes, resolved_call_ids, genv)
  end

  private

  # module_function publishes a single `def` as both an instance and a
  # singleton method, so the two must always be renamed together.
  #
  # The pair is identified by both entities pointing at the same def node —
  # an explicit `def self.foo` alongside `def foo` yields two distinct nodes
  # and must stay independent. The older "no defs but has call boxes" shape
  # is still accepted: TypeProf only began recording a def for the singleton
  # side of module_function in 0.32.0.
  def link_module_function_variant(genv, node, cpath, singleton, mid, method_key)
    alt_entity = genv.resolve_method(cpath, !singleton, mid) rescue nil
    return unless alt_entity
    shares_def_node = alt_entity.defs.to_a.any? { |d| d.node.equal?(node) }
    call_only = alt_entity.defs.size == 0 && alt_entity.method_call_boxes.size > 0
    return unless shares_def_node || call_only
    alt_key = [cpath, !singleton, mid].freeze
    @method_rename_mapping.add_method(alt_key, nil)
    @method_rename_mapping.merge_groups(method_key, alt_key)
  end

  def resolve_def_receiver_cpath(receiver, genv)
    cpath = case receiver
    when Prism::ConstantReadNode
      [receiver.name]
    when Prism::ConstantPathNode
      build_cpath_from_prism_node(receiver)
    end
    return nil unless cpath

    genv.resolve_cpath(cpath)
    cpath
  rescue
    nil
  end

  def build_cpath_from_prism_node(node)
    parts = []
    current = node
    while current.is_a?(Prism::ConstantPathNode)
      parts.unshift(current.name)
      current = current.parent
    end
    if current.is_a?(Prism::ConstantReadNode)
      parts.unshift(current.name)
    elsif current.nil?
      # ::Foo::Bar (top-level absolute path)
    else
      return nil
    end
    parts
  end

  def merge_super_groups(super_merges)
    super_merges.each do |child_key, parent_key|
      @method_rename_mapping.merge_groups(child_key, parent_key) if @method_rename_mapping.has_method?(child_key)
    end
  end

  def merge_polymorphic_groups(call_node_to_keys)
    call_node_to_keys.each_value do |keys|
      next if keys.size < 2
      (1...keys.size).each { |i| @method_rename_mapping.merge_groups(keys[i - 1], keys[i]) }
    end
  end

  def merge_unresolved_calls(nodes, resolved_call_ids, genv)
    method_mids = @method_rename_mapping.method_mids
    unresolved_by_mid = Hash.new { |h, k| h[k] = [] }

    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::CallNode,
           TypeProf::Core::AST::CallWriteNode,
           TypeProf::Core::AST::CallReadNode
        if method_mids.include?(node.mid) && !resolved_call_ids.include?(node.object_id)
          unresolved_by_mid[node.mid] << node
        end
      end
    end

    exclude_mids = Set.new
    unresolved_by_mid.each do |mid, call_nodes|
      mapped_calls = []
      should_exclude = false

      call_nodes.each do |node|
        verdict = classify_unresolved_call(mid, node, genv)
        case verdict
        when :mapped  then mapped_calls << node
        when :exclude then should_exclude = true; break
        # :unrelated — call targets a different class's method, skip
        end
      end

      if should_exclude
        exclude_mids << mid
      elsif mapped_calls.any?
        @method_rename_mapping.merge_all_by_mid(mid)
        @method_rename_mapping.add_unresolved_sites_for_mid(mid, mapped_calls)
      end
    end
    @method_rename_mapping.exclude_methods_by_mid(exclude_mids) unless exclude_mids.empty?
  end

  def classify_unresolved_call(mid, node, genv)
    recv = node.recv
    return :mapped unless recv

    resolved_any = false
    all_mapped = true
    node.boxes(:mcall) do |box|
      box.resolve(genv, nil) do |me, ty, _resolved_mid, _orig_ty|
        next unless me
        resolved_any = true
        singleton = ty.is_a?(TypeProf::Core::Type::Singleton)
        all_mapped = false unless @method_rename_mapping.has_method?([ty.mod.cpath, singleton, mid])
      end
    end

    return (all_mapped ? :mapped : :unrelated) if resolved_any

    :exclude
  end

  public

  def scan_dynamic_method_references(nodes)
    dynamic_mids = Set.new
    nodes.traverse do |event, node|
      next unless event == :enter
      next unless node.is_a?(TypeProf::Core::AST::CallNode)
      next unless DYNAMIC_DISPATCH_METHODS.include?(node.mid)

      sym_arg = node.positional_args&.first
      next unless sym_arg
      ret = sym_arg.ret rescue nil
      next unless ret

      ret.types.each_key do |ty|
        dynamic_mids << ty.sym if ty.is_a?(TypeProf::Core::Type::Symbol)
      end
    end
    @method_rename_mapping.exclude_methods_by_mid(dynamic_mids) unless dynamic_mids.empty?
  end

  # send/public_send/__send__ are NOT listed here because TypeProf resolves
  # them as MethodCallBoxes on the target method. resolve_method_calls
  # handles grouping automatically, and MethodRenamer patches the symbol arg.
  DYNAMIC_DISPATCH_METHODS = %i[
    method define_method respond_to? instance_method
  ].freeze

  VISIBILITY_MODIFIERS = %i[private protected public module_function].freeze

  def collect_visibility_modifier_methods(nodes)
    excluded_mids = Set.new
    nodes.traverse do |event, node|
      next unless event == :enter
      next unless node.is_a?(TypeProf::Core::AST::CallNode)
      next unless VISIBILITY_MODIFIERS.include?(node.mid)

      node.positional_args&.each do |arg|
        excluded_mids << arg.lit if arg.is_a?(TypeProf::Core::AST::SymbolNode)
      end
    end
    @method_rename_mapping.exclude_methods_by_mid(excluded_mids) unless excluded_mids.empty?
  end

  def collect_alias_undef_methods(nodes)
    excluded_mids = Set.new
    nodes.traverse do |event, node|
      next unless event == :enter
      case node
      when TypeProf::Core::AST::AliasNode
        excluded_mids << node.new_mid.lit if node.new_mid.respond_to?(:lit)
        excluded_mids << node.old_mid.lit if node.old_mid.respond_to?(:lit)
      when TypeProf::Core::AST::UndefNode
        node.names.each { |n| excluded_mids << n.lit if n.respond_to?(:lit) }
      end
    end
    @method_rename_mapping.exclude_methods_by_mid(excluded_mids) unless excluded_mids.empty?
  end
end
