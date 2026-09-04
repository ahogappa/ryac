# frozen_string_literal: true

module Ryac
  # Lexical scope analysis for local variables, done entirely on the Prism
  # tree.
  #
  # Locals are the one namespace Ruby resolves purely lexically, and Prism
  # hands us that resolution ready-made: every scope node carries `locals` in
  # declaration order, and every variable node carries `depth` — the exact
  # number of scope hops to its declaring scope. TypeProf's view of the same
  # information (lenv/cref chains, tbl) is reconstructed for type inference
  # and had to be joined back to source positions; using it here meant the
  # renamer's single largest data flow ran across that seam for information
  # the syntax tree already had.
  #
  # Three phases, called in order:
  #   1. build (initialize) — walk the tree once, record every scope
  #   2. allocate           — assign short names per scope
  #   3. resolve            — map every variable occurrence to its final name
  #
  # Phases are split because keyword-argument hints arrive between 1 and 2:
  # they are keyed by the scope containing the call site, which requires the
  # scope structure, and they influence which names a def hands out.
  class LocalScopes
    include RenameInvariants

    DYNAMIC_VARIABLE_METHODS = %i[
      eval instance_eval class_eval module_eval
      binding local_variable_get local_variable_set
    ].freeze

    NUMBERED_PARAM_RE = /\A_\d+\z/

    Scope = Struct.new(:id, :kind, :node, :parent, :owner_call, :mapping, keyword_init: true) do
      # declared on the Scope class itself in the RBS
      def allocated? = !mapping.nil? # steep:ignore UndeclaredMethodDefinition, NoMethod
    end

    attr_reader :scopes

    def initialize(program_node)
      @program = program_node
      @scopes = []
      @scope_by_node = {}
      @children = {}
      @constraints = {}
      build(program_node)
    end

    # Innermost scope containing the given byte offset. Used to attach
    # information that arrives keyed by "the scope around this node" —
    # keyword hints and implicit-receiver call sites.
    def scope_id_at(offset)
      best = nil #: Scope?
      @scopes.each do |scope|
        range = scope_range(scope)
        next unless range.cover?(offset)
        best = scope if best.nil? || range.begin >= scope_range(best).begin
      end
      best&.id
    end

    def scope_id_of(node)
      # [0], not .first: the .first→[0] transform is oracle-gated, and a
      # site the oracle resolves on one self-host pass but not the other
      # drifts the fixed point by a byte. lib spells the target form.
      scope_id_at(AstUtils.location_key(node)[0])
    end

    # Phase 2: assign short names. kw_def_map is keyed by def location_key,
    # var_hints by scope id; both may be empty.
    def allocate(kw_def_map: {}, var_hints: {})
      @scopes.each do |scope|
        case scope.kind
        when :top   then allocate_top(scope)
        when :def   then allocate_def(scope, kw_def_map, var_hints)
        when :block then allocate_block(scope) if scope.owner_call
        end
      end
      self
    end

    # {scope_id => {original => short}} for every scope that allocates names.
    def scope_mappings
      @scopes.each_with_object({}) do |scope, out| #$ scope_mapping_table
        # allocated? guarantees mapping is non-nil here.
        out[scope.id] = scope.mapping if scope.allocated? # steep:ignore ArgumentTypeMismatch
      end
    end

    # {scope_id => post-rename local names visible inside that scope}: its own
    # locals plus those of enclosing scopes, looking through block and lambda
    # boundaries the way variable lookup does. Locals a scope keeps (never
    # renamed, or already short) count the same as renamed ones — a bare call
    # whose new name matches any visible local parses as that local, not the
    # method, so collision guards must see the full set.
    def visible_local_names
      @scopes.to_h do |scope|
        names = Set.new #: Set[String]
        current = scope #: Scope?
        while current
          mapping = current.mapping || {}
          current.node.locals.each { |var| names << (mapping[var] || var.to_s) }
          break unless %i[block lambda].include?(current.kind)
          current = current.parent
        end
        [scope.id, names]
      end
    end

    # Phase 3 outputs.
    attr_reader :rename_entries, :def_param_names, :block_param_names, :for_index_names

    def resolve
      @rename_entries = {}
      @def_param_names = {}
      @block_param_names = {}
      @for_index_names = {}
      resolve_walk(@program, [])
      self
    end

    private

    def scope_range(scope)
      loc = scope.node.location
      loc.start_offset..loc.end_offset
    end

    # === Phase 1: structure ===

    def add_scope(kind, node, parent, owner_call: nil)
      scope = Scope.new(id: AstUtils.location_key(node), kind: kind, node: node,
                        parent: parent, owner_call: owner_call, mapping: nil)
      @scopes << scope
      @scope_by_node[node.object_id] = scope
      (@children[parent.object_id] ||= []) << scope if parent
      scope
    end

    def build(node, current = nil, owner_call: nil)
      return unless node.is_a?(Prism::Node)

      case node
      when Prism::ProgramNode
        scope = add_scope(:top, node, current)
        node.compact_child_nodes.each { |c| build(c, scope) }
      when Prism::DefNode
        # The receiver of `def x.foo` reads an outer local; parameters and
        # body live in the fresh method scope.
        build(node.receiver, current) if node.receiver
        scope = add_scope(:def, node, current)
        build(node.parameters, scope)
        build(node.body, scope)
      when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        # Their bodies can hold locals, but renaming never touches them —
        # the scope exists so depth arithmetic stays exact.
        node.compact_child_nodes.each do |c|
          if c.equal?(node.body)
            scope = add_scope(:class, node, current)
            build(c, scope)
          else
            build(c, current)
          end
        end
      when Prism::CallNode
        node.compact_child_nodes.each do |c|
          if c.equal?(node.block) && c.is_a?(Prism::BlockNode)
            build(c, current, owner_call: node)
          else
            build(c, current)
          end
        end
      when Prism::BlockNode
        scope = add_scope(:block, node, current, owner_call: owner_call)
        node.compact_child_nodes.each { |c| build(c, scope) }
      when Prism::LambdaNode
        # Parity with the previous implementation: lambda params and locals
        # keep their names. The scope still participates in depth counting.
        scope = add_scope(:lambda, node, current)
        node.compact_child_nodes.each { |c| build(c, scope) }
      else
        node.compact_child_nodes.each { |c| build(c, current, owner_call: nil) }
      end
    end

    # === Phase 2: allocation ===

    def allocate_top(scope)
      locals = scope.node.locals
      return unless locals.any?

      unsafe, pinned = constraints_for(scope)
      generator = NameGenerator.new(pinned.map(&:to_s) + reserved_names(scope))
      mapping = {} #: Hash[Symbol, String]
      locals.each do |var|
        mapping[var] = allocated_name(var, unsafe, pinned, generator)
      end
      verify_injective!(mapping, 'top-level')
      scope.mapping = mapping
    end

    def allocate_def(scope, kw_def_map, var_hints)
      node = scope.node #: Prism::DefNode
      return unless node.body

      unsafe, pinned = constraints_for(scope)
      keyword_params = keyword_param_names(node)
      unused_rescue = unused_rescue_vars(node.body)
      kw_mapping = kw_def_map[scope.id]
      hints = var_hints[scope.id] || {}
      # A hint aimed at a local that is itself a keyword parameter can never
      # apply — the parameter branch below always wins — so reserving its
      # value would only burn a short name. Worse, the waste is not a fixed
      # point: re-minifying the output (where the hinting call already writes
      # short keywords, so no hint arises) would allocate the burned names.
      hints = hints.reject { |var, _| keyword_params.include?(var) }
      # An unused rescue variable is left as written, and so is every name
      # reserved_names lists; a hint or an allocation landing on one of them
      # would bind two variables to one name.
      kept = unused_rescue.map(&:to_s) + reserved_names(scope)
      hints = hints.reject { |_, name| kept.include?(name) }

      reserved = hints.values.dup
      reserved.concat(kw_mapping.values) if kw_mapping
      reserved.concat(pinned.map(&:to_s))
      reserved.concat(kept)
      keyword_names = {} #: Hash[Symbol, String]
      keyword_params.each do |kw|
        keyword_names[kw] = kw_mapping&.[](kw) || kw.to_s
        reserved << keyword_names[kw]
      end

      generator = NameGenerator.new(reserved.uniq)
      mapping = {} #: Hash[Symbol, String]
      claimed = Set.new(keyword_names.values)
      node.locals.each do |var|
        next if unused_rescue.include?(var)
        if pinned.include?(var)
          mapping[var] = var.to_s
          claimed << var.to_s
        elsif keyword_names.key?(var)
          mapping[var] = keyword_names[var]
        elsif !unsafe && hints.key?(var) && !claimed.include?(hints[var])
          mapping[var] = hints[var]
          claimed << hints[var]
        else
          name = unsafe ? var.to_s : generator.next_name
          mapping[var] = name
          claimed << name
        end
      end
      verify_injective!(mapping, "def #{node.name}")
      scope.mapping = mapping
    end

    def allocate_block(scope)
      node = scope.node #: Prism::BlockNode
      return unless node.body

      unsafe, pinned = constraints_for(scope)
      f_args = block_formal_names(node)
      parent_names = ancestor_visible_names(scope) + reserved_names(scope)
      reserved = parent_names + pinned.map(&:to_s)

      if !unsafe && use_numbered_params?(node, f_args, parent_names)
        mapping = {} #: Hash[Symbol, String]
        # use_numbered_params? returns false when f_args contains nil, so every
        # param here is a Symbol.
        f_args.each_with_index { |param, idx| mapping[param] = "_#{idx + 1}" } # steep:ignore ArgumentTypeMismatch
      else
        generator = NameGenerator.new(reserved)
        mapping = {} #: Hash[Symbol, String]
        f_args.each do |param|
          next unless param
          next if param.to_s.match?(/\A_\d*\z/)
          mapping[param] = allocated_name(param, unsafe, pinned, generator)
        end
        block_multi_targets(node).each do |mt|
          collect_multi_target_names(mt).each do |name|
            mapping[name] = allocated_name(name, unsafe, pinned, generator)
          end
        end
      end

      if (params = block_parameters(node))
        generator ||= NameGenerator.new(reserved)
        collect_extra_block_param_names(params).each do |name|
          next if mapping.key?(name)
          mapping[name] = allocated_name(name, unsafe, pinned, generator)
        end

        # Numbered parameters cannot coexist with optionals, rest, keywords
        # or a block param — those force an explicit pipe list, so any _N
        # picked above has to become an ordinary name.
        if block_has_non_required_params?(params)
          numbered = mapping.select { |_, v| v.match?(NUMBERED_PARAM_RE) }
          if numbered.any?
            gen = NameGenerator.new(mapping.values.reject { |v| v.match?(NUMBERED_PARAM_RE) })
            numbered.each_key { |param| mapping[param] = gen.next_name }
          end
        end
      end

      # allocate only calls this when scope.owner_call is present.
      owner_label = scope.owner_call.name # steep:ignore NoMethod
      verify_injective!(mapping, "block for #{owner_label}")
      scope.mapping = mapping
    end

    # The names a scope's allocation must not hand out on account of what
    # the scope itself and the blocks and lambdas nested in it keep as
    # written. A block's body locals and a lambda's names are never renamed,
    # and Ruby resolves them by spelling: an outer name allocated onto one
    # of them turns the inner assignment into a write to the outer variable
    # (optcarrot's palette — `|rf, gf, bf|` renamed to `|a, b, c|` over an
    # inner `b = ...`). A block adds ancestor_visible_names on top.
    def reserved_names(scope)
      kept_local_names(scope) + descendant_kept_names(scope)
    end

    # What a block sees from outside: every allocated ancestor's names, all
    # the way to the top — visibility actually ends at the first def
    # boundary, so anything beyond it is over-reservation, but the
    # allocation order downstream is built around this exact set, and
    # narrowing it reshuffles names without making any of them safer — plus
    # the kept locals of the blocks and lambdas up to that boundary. A
    # parameter allocated onto one of those would shadow what its body
    # still reads.
    def ancestor_visible_names(scope)
      names = [] #: Array[String]
      visible = true
      current = scope.parent
      while current
        # allocated? guarantees mapping is non-nil here.
        names.concat(current.mapping.values) if current.allocated? # steep:ignore NoMethod
        names.concat(kept_local_names(current)) if visible
        visible &&= %i[block lambda].include?(current.kind)
        current = current.parent
      end
      names
    end

    # Kept names of every block and lambda nested in the scope, as far as
    # variable lookup reaches: a def or class boundary ends the descent.
    def descendant_kept_names(scope)
      names = [] #: Array[String]
      stack = (@children[scope.object_id] || []).dup
      until stack.empty?
        child = stack.pop #: Scope
        next unless %i[block lambda].include?(child.kind)

        names.concat(kept_local_names(child))
        stack.concat(@children[child.object_id] || [])
      end
      names
    end

    # The locals a scope leaves as written: a block renames only its
    # parameters — its body locals, and the parameters it pins or leaves
    # under eval, stay — and a lambda renames nothing.
    def kept_local_names(scope)
      node = scope.node
      case scope.kind
      when :block
        unsafe, pinned = constraints_for(scope)
        return node.locals.map(&:to_s) if unsafe

        # @type var node: Prism::BlockNode
        renamed = renamed_block_param_names(node)
        node.locals.filter_map { |var| var.to_s if pinned.include?(var) || !renamed.include?(var) }
      when :lambda
        node.locals.map(&:to_s)
      else
        []
      end
    end

    def renamed_block_param_names(node)
      names = block_formal_names(node).compact.reject { |p| p.to_s.match?(/\A_\d*\z/) }
      block_multi_targets(node).each { |mt| names.concat(collect_multi_target_names(mt)) }
      params = block_parameters(node)
      names.concat(collect_extra_block_param_names(params)) if params
      names.to_set
    end

    # scope_constraints, once per scope: reserved_names asks about every
    # nested block repeatedly.
    def constraints_for(scope)
      @constraints[scope.id] ||= begin
        node = scope.node
        body = node.is_a?(Prism::ProgramNode) ? node.statements : node.body
        scope_constraints(body)
      end
    end

    # One walk answers both per-scope safety questions: whether the scope
    # defeats renaming entirely (eval and friends can read any local by its
    # original name) and which locals are name-pinned — a regex named
    # capture writes the local named after the group, and a hash-pattern
    # shorthand (`in { value: }`) binds the local named after the key it
    # matches. Renaming a pinned local breaks the pairing the name encodes;
    # the regex/pattern half keeps the original.
    def scope_constraints(body)
      unsafe = false
      pinned = Set.new
      walk_all(body) do |n|
        case n
        when Prism::CallNode
          unsafe = true if DYNAMIC_VARIABLE_METHODS.include?(n.name)
        when Prism::MatchWriteNode
          n.targets.each { |t| pinned << t.name if t.is_a?(Prism::LocalVariableTargetNode) }
        when Prism::HashPatternNode
          n.elements.each do |e|
            next unless e.is_a?(Prism::AssocNode) && e.value.is_a?(Prism::ImplicitNode)
            target = e.value.value
            pinned << target.name if target.is_a?(Prism::LocalVariableTargetNode)
          end
        end
      end
      [unsafe, pinned]
    end

    # The unsafe/pinned/generator decision every allocator makes per name.
    def allocated_name(var, unsafe, pinned, generator)
      unsafe || pinned.include?(var) ? var.to_s : generator.next_name
    end

    def unused_rescue_vars(body)
      unused = Set.new
      walk_all(body) do |n|
        next unless n.is_a?(Prism::RescueNode)
        ref = n.reference
        next unless ref.is_a?(Prism::LocalVariableTargetNode)

        used = false
        walk_all(n.statements) do |child|
          used = true if child.is_a?(Prism::LocalVariableReadNode) && child.name == ref.name
        end
        unused << ref.name unless used
      end
      unused
    end

    def keyword_param_names(def_node)
      params = def_node.parameters
      return [] unless params

      names = [] #: Array[Symbol]
      params.keywords&.each do |kw|
        names << kw.name if kw.respond_to?(:name)
      end
      names
    end

    def block_parameters(block_node)
      p = block_node.parameters
      p.is_a?(Prism::BlockParametersNode) ? p.parameters : nil
    end

    # The "formal" params: requireds (nil for a destructuring target) plus
    # optionals, in declaration order. Rest, posts, keywords and the block
    # param are handled as extras — this split decides numbered-param
    # eligibility and allocation order, so it must not drift.
    def block_formal_names(block_node)
      params = block_parameters(block_node)
      return [] unless params

      names = params.requireds.map { |r| r.is_a?(Prism::RequiredParameterNode) ? r.name : nil }
      params.optionals.each { |o| names << o.name }
      names
    end

    def block_multi_targets(block_node)
      params = block_parameters(block_node)
      return [] unless params

      params.requireds.select { |r| r.is_a?(Prism::MultiTargetNode) } #: Array[Prism::MultiTargetNode]
    end

    def use_numbered_params?(block_node, f_args, parent_names)
      return false unless f_args.any?
      return false unless block_node.body
      return false if f_args.include?(nil)
      return false if f_args.any? { |p| p.to_s.match?(NUMBERED_PARAM_RE) }
      return false if parent_names.any? { |n| n.match?(NUMBERED_PARAM_RE) }

      param_set = f_args.to_set
      ref_counts = Hash.new(0)
      nested = false
      written = false
      walk_all(block_node.body) do |child|
        case child
        when Prism::BlockNode, Prism::LambdaNode
          nested = true
        when Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode,
             Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
             Prism::LocalVariableAndWriteNode
          written = true if param_set.include?(child.name)
        when Prism::LocalVariableReadNode
          ref_counts[child.name] += 1 if param_set.include?(child.name)
        end
      end
      return false if nested || written

      highest_used = 0
      f_args.each_with_index do |param, idx|
        highest_used = idx + 1 if ref_counts[param] > 0
      end
      return false if highest_used < f_args.size

      generator = NameGenerator.new(parent_names)
      mangled = f_args.map { generator.next_name }
      pipe_overhead = 2 + mangled.sum(&:length) + mangled.size - 1
      reference_overhead = f_args.each_with_index.sum do |param, idx|
        ("_#{idx + 1}".size - mangled[idx].size) * ref_counts[param]
      end
      pipe_overhead - reference_overhead > 0
    end

    def collect_multi_target_names(multi_target_node)
      names = [] #: Array[Symbol]
      multi_target_node.lefts.each do |p|
        if p.is_a?(Prism::RequiredParameterNode)
          names << p.name
        elsif p.is_a?(Prism::MultiTargetNode)
          names.concat(collect_multi_target_names(p))
        end
      end
      rest = multi_target_node.rest
      if rest.is_a?(Prism::SplatNode) && rest.expression.is_a?(Prism::RequiredParameterNode)
        names << rest.expression.name
      end
      names
    end

    def collect_extra_block_param_names(prism_params)
      names = [] #: Array[Symbol]
      prism_params.optionals&.each { |p| names << p.name }
      names << prism_params.rest.name if prism_params.rest.is_a?(Prism::RestParameterNode) && prism_params.rest.name
      prism_params.posts&.each { |p| names << p.name if p.is_a?(Prism::RequiredParameterNode) }
      prism_params.keywords&.each { |p| names << p.name }
      names << prism_params.keyword_rest.name if prism_params.keyword_rest.is_a?(Prism::KeywordRestParameterNode) && prism_params.keyword_rest.name
      names << prism_params.block.name if prism_params.block.is_a?(Prism::BlockParameterNode) && prism_params.block.name
      names
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

    # Walks everything below a node, including nested scopes. Used for the
    # per-scope safety checks, which deliberately look through nesting: an
    # `eval` anywhere below a def taints the def.
    def walk_all(node, &block)
      return unless node.is_a?(Prism::Node)
      yield node
      node.compact_child_nodes.each { |c| walk_all(c, &block) }
    end

    # === Phase 3: resolution ===

    VARIABLE_NODES = [
      Prism::LocalVariableReadNode,
      Prism::LocalVariableWriteNode,
      Prism::LocalVariableTargetNode,
      Prism::LocalVariableOperatorWriteNode,
      Prism::LocalVariableOrWriteNode,
      Prism::LocalVariableAndWriteNode
    ].freeze

    def resolve_walk(node, stack)
      return unless node.is_a?(Prism::Node)

      if (scope = @scope_by_node[node.object_id])
        enter_scope(scope, stack)
        case node
        when Prism::DefNode
          # Receiver resolves outside the scope we just entered.
          if node.receiver
            stack.pop
            resolve_walk(node.receiver, stack)
            stack.push(scope)
          end
          record_def_params(node, scope)
          resolve_walk(node.parameters, stack)
          resolve_walk(node.body, stack)
        when Prism::BlockNode
          record_block_params(node, scope)
          node.compact_child_nodes.each { |c| resolve_walk(c, stack) }
        else
          node.compact_child_nodes.each { |c| resolve_walk(c, stack) }
        end
        stack.pop
        return
      end

      case node
      when *VARIABLE_NODES
        # @type var node: prism_variable_node
        record_variable(node, stack)
      when Prism::ForNode
        record_for_index(node, stack)
      end

      node.compact_child_nodes.each { |c| resolve_walk(c, stack) }
    end

    def enter_scope(scope, stack)
      stack.push(scope)
    end

    def record_variable(node, stack)
      @rename_entries[AstUtils.location_key(node)] = resolved_name(node.name, node.depth, stack)
    end

    def resolved_name(name, depth, stack)
      return name.to_s if name.to_s.match?(NUMBERED_PARAM_RE)

      scope = stack[stack.size - 1 - depth]
      scope&.mapping&.[](name) || name.to_s
    end

    def record_def_params(def_node, scope)
      params = def_node.parameters
      return unless params

      mapping = scope.mapping || {}
      names = {} #: Hash[Symbol, String]
      each_def_param_name(params) { |sym| names[sym] = mapping[sym] || sym.to_s }
      return unless names.any?

      @def_param_names[AstUtils.line_col_key(def_node)] = names
    end

    def each_def_param_name(params, &block)
      params.requireds.each { |p| yield p.name if p.is_a?(Prism::RequiredParameterNode) }
      params.optionals.each { |p| yield p.name }
      yield params.rest.name if params.rest.is_a?(Prism::RestParameterNode) && params.rest.name
      params.posts.each { |p| yield p.name if p.is_a?(Prism::RequiredParameterNode) }
      params.keywords.each { |p| yield p.name if p.respond_to?(:name) }
      yield params.keyword_rest.name if params.keyword_rest.is_a?(Prism::KeywordRestParameterNode) && params.keyword_rest.name
      yield params.block.name if params.block.is_a?(Prism::BlockParameterNode) && params.block.name
    end

    def record_block_params(block_node, scope)
      call = scope.owner_call
      return unless call

      params = block_parameters(block_node)
      f_args = block_formal_names(block_node)
      extra = params ? collect_extra_block_param_names(params) : [] #: Array[Symbol]
      return unless f_args.compact.any? || extra.any?

      mapping = scope.mapping || {}
      names = {} #: Hash[Symbol, String]
      f_args.each { |p| names[p] = mapping[p] || p.to_s if p }
      block_multi_targets(block_node).each do |mt|
        collect_multi_target_names(mt).each { |n| names[n] = mapping[n] || n.to_s }
      end
      extra.each { |n| names[n] = mapping[n] || n.to_s unless names.key?(n) }

      @block_param_names[AstUtils.location_key(call)] = names
    end

    def record_for_index(for_node, stack)
      idx = for_node.index
      return unless idx.is_a?(Prism::LocalVariableTargetNode)

      @for_index_names[AstUtils.line_col_key(for_node)] = resolved_name(idx.name, idx.depth, stack)
    end
  end
end
