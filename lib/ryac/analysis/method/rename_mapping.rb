# frozen_string_literal: true

module Ryac
  EXCLUDED_METHODS = %i[
    initialize initialize_copy initialize_clone initialize_dup
    method_missing respond_to_missing? const_missing
    inherited included extended prepended
    marshal_dump marshal_load encode_with init_with
    call to_s to_str to_i to_int to_f to_r to_c
    to_a to_ary to_h to_hash to_io to_proc
    inspect hash eql? equal? frozen? nil?
    class is_a? kind_of? instance_of?
    coerce respond_to? dup clone freeze
    each __send__ __id__
    <=> == === != < > <= >= + - * / % ** & | ^ << >> =~ !~
    [] []= ! ~ +@ -@
  ].to_set.freeze

  class MethodRenameMapping
    include UnionFind

    # Below this many saved characters a rename is churn, not compression.
    # KeywordRenameMapping applies the same bar.
    MIN_GROUP_SAVINGS = 2

    MethodGroupEntry = Struct.new(:keys, :original_name, :total_occurrences)

    def initialize
      uf_init
      @methods = {}       # method_key => { def_nodes: [], call_sites: [] }
      @node_to_key = {}   # node_object_id => method_key
      @node_short_names = {} # node_object_id => short_name (after freeze)
      @key_short_names = {} # method_key => short_name (after freeze)
      @implicit_receiver_sites = {} # node_object_id => scope_id (for collision check)
      @frozen = false
    end

    def add_method(method_key, def_node)
      @methods[method_key] ||= { def_nodes: [], call_sites: [] }
      if def_node
        @methods[method_key][:def_nodes] << def_node
        @node_to_key[def_node.object_id] = method_key
      end
      uf_add(method_key)
    end

    def has_method?(method_key)
      @methods.key?(method_key)
    end

    # scope_id names the scope containing an implicit-receiver call site, so
    # the method can avoid short names a visible local already took there — a
    # bare `a` would parse as the local, not the call. The caller resolves it
    # rather than this class holding a resolver: this code minifies itself at
    # L5, and a call through a stored collaborator is exactly the dynamic
    # dispatch TypeProf cannot pin down, leaving the resolver's method
    # renamed on one side and not the other.
    def add_call_site(call_node, method_key, has_receiver:, scope_id: nil)
      @methods[method_key] ||= { def_nodes: [], call_sites: [] }
      @methods[method_key][:call_sites] << call_node
      @node_to_key[call_node.object_id] = method_key

      @implicit_receiver_sites[call_node.object_id] = scope_id if !has_receiver && scope_id
    end

    def exclude_methods_by_mid(mids)
      keys_to_remove = @methods.keys.select { |key| mids.include?(key[2]) }
      keys_to_remove.each do |key|
        data = @methods.delete(key) #: method_data
        data[:def_nodes].each { |n| @node_to_key.delete(n.object_id) }
        data[:call_sites].each do |n|
          @node_to_key.delete(n.object_id)
          @implicit_receiver_sites.delete(n.object_id)
        end
        uf_remove(key)
      end
    end

    def merge_all_by_mid(mid)
      keys = @methods.keys.select { |k| k[2] == mid }
      return if keys.size <= 1
      # keys.size > 1 is guaranteed above, so [1..] cannot be nil
      keys[1..].each { |k| merge_groups(keys[0], k) } # steep:ignore NoMethod
    end

    # Inference can silently miss a caller, leaving a def in a group with no
    # call sites while its mid is called — and therefore renamed — through
    # another group. Runtime dispatch does not share the blind spot: a call
    # site patched to the short name can still land on the def that kept its
    # long one. Any mid renamed anywhere must cover every def of that mid, so
    # the blind groups merge in and rename in lockstep.
    def merge_blind_def_groups
      sited_mids = Set.new
      blind_mids = Set.new
      groups_by_root.each_value do |keys|
        sites = keys.sum { |key| @methods[key][:call_sites].size }
        target = sites > 0 ? sited_mids : blind_mids
        keys.each { |key| target << key[2] }
      end

      (blind_mids & sited_mids).each { |mid| merge_all_by_mid(mid) }
    end

    def add_unresolved_sites_for_mid(mid, call_nodes)
      target_key = @methods.keys.find { |k| k[2] == mid }
      return unless target_key
      call_nodes.each { |node| add_call_site(node, target_key, has_receiver: true) }
    end

    def group_keys(method_key)
      groups_by_root[uf_root(method_key)]
    end

    # Every call site registered for the key's whole rename group — including
    # sites attached by the unresolved-call pass, which type inference alone
    # does not report. Yields the scope id for implicit-receiver sites, nil
    # otherwise.
    def each_group_call_site(method_key)
      group_keys(method_key).each do |key|
        @methods[key][:call_sites].each do |node|
          yield node, @implicit_receiver_sites[node.object_id]
        end
      end
    end

    def assign_short_names(scope_mappings, oracle = nil)
      group_entries = build_group_entries(groups_by_root)
      group_entries.sort_by! { |entry| -(entry.original_name.size * entry.total_occurrences) }

      scope_vars = self.class.build_scope_vars(scope_mappings)
      existing_methods, hierarchy = oracle ? build_existing_method_names(oracle) : [{}, {}] #: [Hash[class_key, Set[String]], hierarchy]

      group_entries.each do |entry|
        short_name = find_shortest_name(entry.keys, scope_vars, existing_methods, hierarchy)

        savings_per_use = entry.original_name.size - short_name.size
        next unless savings_per_use > 0

        total_savings = savings_per_use * entry.total_occurrences
        next unless total_savings > MIN_GROUP_SAVINGS

        assign_short_name(entry.keys, short_name)
        propagate_short_name(entry.keys, short_name, existing_methods, hierarchy)
      end

      verify_no_shadowing!(hierarchy)
      @frozen = true
    end

    # A rename group never spans mids, so after assignment each (cpath,
    # singleton) namespace must map its mids onto distinct final names — a
    # renamed method landing on another's name, renamed or kept, would shadow
    # it and the output would still parse. The module_function regression
    # (instance and singleton halves allocated independently) was exactly this
    # shape; this turns any recurrence into a failed run.
    #
    # The namespace a dispatch actually resolves against is the class plus
    # everything it inherits and includes, so with the hierarchy known the
    # same rule is enforced per inheritance-effective namespace: two mids on
    # one final anywhere along a class's ancestor chain shadow each other.
    def verify_no_shadowing!(hierarchy = {})
      namespaces = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = Set.new } } #: Hash[class_key, Hash[String, Set[Symbol]]]
      @methods.each_key do |key|
        cpath, singleton, mid = key
        final = @key_short_names[key] || mid.to_s
        namespaces[[cpath, singleton]][final] << mid
      end

      namespaces.each do |(cpath, singleton), finals|
        collisions = finals.filter_map { |name, mids| [name, mids.to_a] if mids.size > 1 } #: Array[[String, Array[Symbol]]]
        next if collisions.empty?

        label = "#{cpath.join('::')}#{singleton ? '.' : '#'}"
        raise Pipeline::RenameCollisionError.new(label, collisions)
      end

      (hierarchy[:ancestors] || {}).each do |class_key, ancestor_keys|
        next if ancestor_keys.none?

        merged = Hash.new { |h, k| h[k] = Set.new } #: Hash[String, Set[Symbol]]
        ([class_key] + ancestor_keys).each do |ck|
          next unless namespaces.key?(ck)
          namespaces[ck].each { |final, mids| merged[final].merge(mids) }
        end

        collisions = merged.filter_map { |name, mids| [name, mids.to_a] if mids.size > 1 } #: Array[[String, Array[Symbol]]]
        next if collisions.empty?

        label = "#{class_key[0].join('::')}#{class_key[1] ? '.' : '#'} (with ancestors)"
        raise Pipeline::RenameCollisionError.new(label, collisions)
      end
    end

    def short_name_for(node_location_key)
      @node_short_names[node_location_key]
    end

    def short_name_for_key(method_key)
      @key_short_names[method_key]
    end

    def node_mapping
      @node_short_names.dup
    end

    def each_method_key(&block)
      @methods.each_key(&block)
    end

    def method_mids
      result = Set.new
      @methods.each_key { |key| result << key[2] }
      result
    end

    def each_cpath_for_mid(mid)
      @methods.each_key do |key|
        yield key[0], key[1] if key[2] == mid
      end
    end

    private

    def build_group_entries(groups)
      result = [] #: Array[MethodGroupEntry]
      groups.each_value do |keys|
        mid = keys.first[2]
        next if EXCLUDED_METHODS.include?(mid)
        next if mid.to_s.size <= NameGenerator::KEPT_NAME_MAX

        total_call_sites = keys.sum { |key| @methods[key][:call_sites].size }
        next if total_call_sites == 0

        total_occurrences = keys.sum do |key|
          data = @methods[key]
          data[:def_nodes].size + data[:call_sites].size
        end

        result << MethodGroupEntry.new(keys, mid.to_s, total_occurrences)
      end
      result
    end

    # Class method: the attr coordination inverts scope_mappings the same
    # way for its own collision check, so there is exactly one inversion.
    def self.build_scope_vars(scope_mappings)
      scope_vars = Hash.new { |h, k| h[k] = Set.new } #: Hash[scope_id, Set[String]]
      scope_mappings.each do |cref_id, mapping|
        mapping.each_value { |mangled| scope_vars[cref_id] << mangled }
      end
      scope_vars
    end

    def groups_by_root
      groups = Hash.new { |h, k| h[k] = [] } #: Hash[method_key, Array[method_key]]
      @methods.each_key { |key| groups[uf_root(key)] << key }
      groups
    end

    def build_existing_method_names(oracle)
      result = {} #: Hash[class_key, Set[String]]
      includers = Hash.new { |h, k| h[k] = Set.new } #: Hash[class_key, Set[class_key]]
      ancestors_map = {} #: Hash[class_key, Array[class_key]]

      @methods.each_key do |key|
        cache_key = [key[0], key[1]] #: class_key
        next if result.key?(cache_key)
        names = Set.new
        ancestor_keys = [] #: Array[class_key]
        oracle.each_ancestor_methods(key[0], key[1]) do |ancestor_cpath, s, mids|
          mids.each { |mid| names << mid }
          ancestor_key = [ancestor_cpath, s] #: class_key
          if ancestor_key != cache_key
            includers[ancestor_key] << cache_key
            ancestor_keys << ancestor_key
          end
        end
        next if names.empty? && ancestor_keys.empty?
        result[cache_key] = names
        ancestors_map[cache_key] = ancestor_keys
      end

      hierarchy = { includers: includers, ancestors: ancestors_map } #: hierarchy
      [result, hierarchy]
    end

    def find_shortest_name(keys, scope_vars, existing_methods, hierarchy)
      includers = hierarchy[:includers] || {}
      generator = NameGenerator.new
      loop do
        candidate = generator.next_name
        collides = keys.any? do |key|
          var_collision = @methods[key][:call_sites].any? do |node|
            cref_id = @implicit_receiver_sites[node.object_id]
            cref_id && scope_vars[cref_id].include?(candidate)
          end
          next true if var_collision
          class_key = [key[0], key[1]] #: class_key
          next true if existing_methods[class_key]&.include?(candidate)
          # The name is also visible in every class that inherits or includes
          # this one, where a same-named private helper would shadow it for
          # dispatch through the base — check those namespaces too.
          (includers[class_key] || []).any? { |ck| existing_methods[ck]&.include?(candidate) }
        end
        return candidate unless collides
      end
    end

    def propagate_short_name(keys, short_name, existing_methods, hierarchy)
      includers = hierarchy[:includers] || {}
      ancestors = hierarchy[:ancestors] || {}
      keys.each do |key|
        class_key = [key[0], key[1]] #: class_key
        existing_methods[class_key] ||= Set.new
        existing_methods[class_key] << short_name
        (includers[class_key] || []).each do |ck|
          existing_methods[ck] ||= Set.new
          existing_methods[ck] << short_name
        end
        (ancestors[class_key] || []).each do |ck|
          existing_methods[ck] ||= Set.new
          existing_methods[ck] << short_name
        end
      end
    end

    def assign_short_name(keys, short_name)
      keys.each do |key|
        @key_short_names[key] = short_name
        data = @methods[key]
        data[:def_nodes].each { |n| @node_short_names[AstUtils.location_key(n)] = short_name }
        data[:call_sites].each { |n| @node_short_names[AstUtils.location_key(n)] = short_name }
      end
    end

  end
end
