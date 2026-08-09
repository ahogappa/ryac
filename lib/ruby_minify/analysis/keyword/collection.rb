# frozen_string_literal: true

module RubyMinify
  def collect_keyword_info(prism_root)
    @keyword_def_node_registry = {}
    @keyword_forwarding_super_keys = Set.new

    Nesting.each_method_definition(prism_root) do |node, method_key|
      keywords = def_keyword_names(node)
      next if keywords.empty?

      keywords.each { |sym| @keyword_rename_mapping.add_keyword_def(method_key, sym) }

      @keyword_def_node_registry[method_key] ||= []
      @keyword_def_node_registry[method_key] << node

      @keyword_rename_mapping.exclude_method(method_key) if def_keyword_rest?(node)

      @keyword_forwarding_super_keys << method_key if forwards_parameters_to_super?(node)
    end

    collect_keyword_call_sites(prism_root)
  end

  private

  def def_keyword_names(def_node)
    params = def_node.parameters
    return [] unless params

    names = []
    params.keywords&.each do |kw|
      names << kw.name if kw.respond_to?(:name)
    end
    names
  end

  def def_keyword_rest?(def_node)
    def_node.parameters&.keyword_rest.is_a?(Prism::KeywordRestParameterNode)
  end

  # A bare `super` forwards this method's parameters to the parent by name, so
  # the keyword names have to keep matching the parent's signature. When the
  # parent is a def we also collected, collect_keyword_call_sites merges the
  # two groups and both sides are renamed together; this only reports the
  # forwarding, the decision is made once we know whether that merge happened.
  def forwards_parameters_to_super?(def_node)
    found = false
    walk = lambda do |n|
      return if found || !n.is_a?(Prism::Node)
      # A nested def has its own parameters; its `super` is not about ours.
      return if n.is_a?(Prism::DefNode)
      if n.is_a?(Prism::ForwardingSuperNode)
        found = true
        return
      end
      n.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(def_node.body)
    found
  end

  # Everything call sites decide about keyword renames, in order: literal
  # keywords register with their method, super-forwarding merges child and
  # parent groups (or excludes the child when the parent is outside our
  # control), polymorphic call sites merge every method they can reach,
  # methods no resolved call reaches are excluded, and unresolved
  # keyword-writing calls disqualify their method name entirely.
  def collect_keyword_call_sites(prism_root)
    sites = register_keyword_calls
    merge_super_forwarding(sites[:super_merges])
    merge_polymorphic_keyword_groups(sites[:call_node_to_keys])
    exclude_unreachable_keyword_methods(sites[:zero_call_keys], sites[:super_merges])
    exclude_unresolved_keyword_calls(prism_root, sites[:resolved_site_keys])
  end

  def register_keyword_calls
    call_node_to_keys = Hash.new { |h, k| h[k] = [] }
    super_merges = []
    zero_call_keys = []
    resolved_site_keys = Set.new

    @keyword_rename_mapping.each_method_key do |key|
      call_count = 0
      splat_seen = false

      @oracle.each_caller(key[0], key[1], key[2]) do |info|
        resolved_site_keys << AstUtils.location_key(info.prism_node) if info.prism_node
        next if splat_seen

        if info.super
          super_merges << [[info.caller_cpath, key[1], key[2]].freeze, key]
          next
        end

        call_count += 1

        next unless info.keyword_entries

        if info.keyword_splat
          @keyword_rename_mapping.exclude_method(key)
          splat_seen = true
          next
        end

        info.keyword_entries.each do |sym_node, val_node|
          @keyword_rename_mapping.add_keyword_call(key, sym_node.unescaped.to_sym, sym_node, val_node)
        end

        call_node_to_keys[AstUtils.location_key(info.prism_node)] << key
      end

      zero_call_keys << key if call_count == 0 && @oracle.method_known?(key[0], key[1], key[2])
    end

    { call_node_to_keys: call_node_to_keys, super_merges: super_merges,
      zero_call_keys: zero_call_keys, resolved_site_keys: resolved_site_keys }
  end

  # Supers are discovered from the parent's call boxes, so a `super` whose
  # parent we never collected produces no merge at all. That parent's
  # signature is outside our control — Data.define and Struct.new generate
  # theirs from the member list — and renaming only the child raises
  # "unknown keywords" at runtime, so leave those keywords alone.
  def merge_super_forwarding(super_merges)
    super_merges.each do |child_key, parent_key|
      @keyword_rename_mapping.merge_groups(child_key, parent_key)
    end

    merged_children = Set.new(super_merges.map { |child_key, _| child_key })
    @keyword_forwarding_super_keys.each do |key|
      next if merged_children.include?(key)
      @keyword_rename_mapping.exclude_method(key)
    end
  end

  def merge_polymorphic_keyword_groups(call_node_to_keys)
    call_node_to_keys.each_value do |keys|
      next if keys.size < 2
      (1...keys.size).each { |i| @keyword_rename_mapping.merge_groups(keys[i - 1], keys[i]) }
    end
  end

  # A keyword-taking method type analysis knows but connects no call to is
  # reachable in ways we cannot see; renaming its keywords would strand the
  # unseen callers. A method reached through super stays: the merge already
  # ties it to callers we did see.
  def exclude_unreachable_keyword_methods(zero_call_keys, super_merges)
    super_targets = super_merges.map(&:last).to_set
    zero_call_keys.each do |key|
      next if super_targets.include?(key)
      @keyword_rename_mapping.exclude_method(key)
    end
  end

  # A call to a keyword-taking method that type inference never connected to
  # its target would keep its written keywords while the def's got renamed —
  # so any such call disqualifies the whole method name. Only calls that
  # actually write keywords (literals or a **splat) can go stale, though: a
  # keyword-less call is untouched by the rename no matter which method it
  # reaches, and unrelated methods sharing the name would otherwise poison
  # each other through it.
  def exclude_unresolved_keyword_calls(prism_root, resolved_site_keys)
    keyword_mids = Set.new
    @keyword_rename_mapping.each_method_key { |key| keyword_mids << key[2] }
    return if keyword_mids.empty?

    unresolved_mids = Set.new
    AstUtils.each_node(prism_root) do |node|
      next unless node.is_a?(Prism::CallNode)
      if keyword_mids.include?(node.name) &&
         carries_keyword_arguments?(node) &&
         !resolved_site_keys.include?(AstUtils.location_key(node))
        unresolved_mids << node.name
      end
    end

    unresolved_mids.each do |mid|
      @keyword_rename_mapping.each_method_key do |key|
        @keyword_rename_mapping.exclude_method(key) if key[2] == mid
      end
    end
  end

  def carries_keyword_arguments?(call_node)
    call_node.arguments&.arguments&.any? { |arg| arg.is_a?(Prism::KeywordHashNode) } || false
  end

  public
end
