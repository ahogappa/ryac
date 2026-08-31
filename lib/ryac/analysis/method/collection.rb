# frozen_string_literal: true

module Ryac
  module AnalysisPhases
    def collect_method_definitions(prism_root)
      setter_mids = Set.new
      Nesting.each_method_definition(prism_root) do |node, method_key|
        next if EXCLUDED_METHODS.include?(method_key[2])

        # An explicit `def foo=` keeps its name: short names are allocated
        # per group, so nothing promises the setter would land on
        # `<getter's name>=`, and the def patcher would strip the `=` from
        # any unpaired spelling. The base name is kept with it — a compound
        # write reads through one spelling and writes through the other, so
        # the pair must move in lockstep or not at all (the same doctrine
        # that keeps accessor pairs in compound writes unrenamed).
        # attr-declared setters are different — they rename textually
        # coupled to their getter.
        if AstUtils.setter_def_name?(method_key[2])
          setter_mids << method_key[2] << method_key[2].to_s.chomp('=').to_sym
        end

        @method_rename_mapping.add_method(method_key, node)
        link_module_function_variant(node, method_key)
      end
      @method_rename_mapping.exclude_methods_by_mid(setter_mids) unless setter_mids.empty?

      # attr_reader/attr_accessor define getters worth renaming; attr_writer's
      # setter is derived from the getter name and is never registered on its
      # own.
      each_attr_declaration(prism_root, %i[attr_reader attr_accessor]) do |node, cpath, singleton, mid|
        next if EXCLUDED_METHODS.include?(mid)

        @method_rename_mapping.add_method([cpath, singleton, mid].freeze, node)
      end
    end

    def resolve_method_calls
      call_node_to_keys = Hash.new { |h, k| h[k] = [] } #: Hash[location_key, Array[method_key]]
      resolved_call_keys = Set.new
      super_merges = [] #: Array[[method_key, method_key]]
      sig_dispatch_mids = Set.new

      @method_rename_mapping.each_method_key do |key|
        @oracle.each_caller(key[0], key[1], key[2]) do |info|
          if info.super
            # caller_cpath is always present on super records
            entry = [info.caller_cpath, key[1], key[2]].freeze #: method_key
            super_merges << [entry, key]
            next
          end

          if info.prism_node.nil?
            # The dispatch happens inside an RBS declaration, so there is no
            # source site to rewrite; the name must survive on every class.
            sig_dispatch_mids << key[2]
            next
          end

          scope_id = info.receiver ? nil : @local_scopes.scope_id_of(info.prism_node)
          @method_rename_mapping.add_call_site(info.prism_node, key, has_receiver: info.receiver, scope_id: scope_id)
          loc = AstUtils.location_key(info.prism_node)
          call_node_to_keys[loc] << key
          resolved_call_keys << loc
        end
      end

      @method_rename_mapping.exclude_methods_by_mid(sig_dispatch_mids) unless sig_dispatch_mids.empty?
      merge_super_groups(super_merges)
      merge_polymorphic_groups(call_node_to_keys)
      merge_unresolved_calls(resolved_call_keys)
      # Folding blind defs into same-name sited groups is a probability
      # bet, not a proof — the aggressive policy's territory.
      @method_rename_mapping.merge_blind_def_groups if @method_policy == :aggressive
    end

    # Renaming an attr declaration renames its backing ivar with it. In a
    # class that touches ivars dynamically (optcarrot's Config assigns
    # every option via instance_variable_set), the dynamic side keeps the
    # original spelling and a renamed reader silently returns nil. The
    # ivar renamer already refuses such classes; the attr names there must
    # survive for the same reason, under either policy.
    def collect_dynamic_ivar_attr_exclusions(prism_root)
      dynamic_cpaths = Set.new
      Nesting.each(prism_root) do |node, cpath, _singleton, _in_def|
        next unless node.is_a?(Prism::CallNode) && DYNAMIC_IVAR_METHODS.include?(node.name)

        recv = node.receiver
        dynamic_cpaths << cpath if recv.nil? || recv.is_a?(Prism::SelfNode)
      end
      return if dynamic_cpaths.empty?

      excluded = Set.new
      each_attr_declaration(prism_root, ATTR_DECLARATION_METHODS, require_class_body: false) do |_node, cpath, _singleton, sym|
        excluded << sym << :"#{sym}=" if dynamic_cpaths.include?(cpath)
      end
      @method_rename_mapping.exclude_methods_by_mid(excluded) unless excluded.empty?
    end

    # eval and send-by-string dispatch from strings, not the syntax tree:
    # a method whose name is spelled inside any string literal may be
    # called from text the renamer cannot rewrite, so under the safe
    # policy it keeps its name. Setters count as mentioned when their
    # base word is.
    def collect_string_literal_mentions(prism_root)
      words = Set.new
      AstUtils.each_node(prism_root) do |node|
        next unless node.is_a?(Prism::StringNode)

        # the pattern has no capture groups, so scan only produces strings;
        # the is_a? narrows the union scan's signature declares
        node.unescaped.scan(/[a-zA-Z_][a-zA-Z0-9_]*[?!]?/).each do |w|
          words << w.to_sym if w.is_a?(String)
        end
      end
      return if words.empty?

      mentioned = @method_rename_mapping.method_mids.select { |mid|
        words.include?(mid) || words.include?(mid.to_s.chomp('=').to_sym)
      }
      @method_rename_mapping.exclude_methods_by_mid(mentioned.to_set) unless mentioned.empty?
    end

    # Visibility resets at every reopen of this module, so each collection
    # file's `private` covers that file alone.
    private

    # module_function publishes a single `def` as both an instance and a
    # singleton method, so the two must always be renamed together.
    #
    # The pair is identified by both entities pointing at the same definition
    # site — an explicit `def self.foo` alongside `def foo` is two sites and
    # must stay independent. The "no defs but has call boxes" shape is also
    # accepted: older TypeProf releases recorded no def at all for the
    # singleton side of module_function.
    def link_module_function_variant(def_node, method_key)
      cpath, singleton, mid = method_key
      return unless @oracle.method_known?(cpath, !singleton, mid)

      alt_def_keys = @oracle.method_definition_keys(cpath, !singleton, mid)
      shares_definition = alt_def_keys.include?(AstUtils.location_key(def_node))
      call_only = alt_def_keys.empty? && @oracle.method_call_count(cpath, !singleton, mid) > 0
      return unless shares_definition || call_only

      alt_key = [cpath, !singleton, mid].freeze
      @method_rename_mapping.add_method(alt_key, nil)
      @method_rename_mapping.merge_groups(method_key, alt_key)
    end

    def merge_super_groups(super_merges)
      super_merges.each do |child_key, parent_key|
        @method_rename_mapping.merge_groups(child_key, parent_key) if @method_rename_mapping.has_method?(child_key)
      end
    end

    # One call site reaching the same method name on several classes is
    # polymorphism: merge, so every receiver renames in lockstep. One call site
    # reaching several *different* names is a computed dispatch — optcarrot's
    # `send(mode)` resolves to imm/zpg/abs/… at once — and "merging" that would
    # assign one short name to all of them, collapsing distinct methods into
    # whichever def lands last. Those names must simply survive.
    def merge_polymorphic_groups(call_node_to_keys)
      computed_dispatch_mids = Set.new
      call_node_to_keys.each_value do |keys|
        next if keys.size < 2

        mids = keys.map { |k| k[2] }.uniq
        if mids.size > 1
          computed_dispatch_mids.merge(mids)
          next
        end

        (1...keys.size).each { |i| @method_rename_mapping.merge_groups(keys[i - 1], keys[i]) }
      end
      @method_rename_mapping.exclude_methods_by_mid(computed_dispatch_mids) unless computed_dispatch_mids.empty?
    end

    UNRESOLVED_CALL_NODES = [
      Prism::CallNode,
      Prism::CallOperatorWriteNode,
      Prism::CallOrWriteNode,
      Prism::CallAndWriteNode
    ].freeze

    def merge_unresolved_calls(resolved_call_keys)
      method_mids = @method_rename_mapping.method_mids
      unresolved_by_mid = Hash.new { |h, k| h[k] = [] } #: Hash[Symbol, Array[Prism::Node]]

      AstUtils.each_node(@prism_root) do |node|
        mids = case node
        when Prism::CallNode
          [node.name]
        when Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
          [node.read_name, node.write_name]
        else
          next
        end

        loc = AstUtils.location_key(node)
        next if resolved_call_keys.include?(loc)

        mids.each do |mid|
          unresolved_by_mid[mid] << node if method_mids.include?(mid)
        end
      end

      exclude_mids = Set.new
      unresolved_by_mid.each do |mid, call_nodes|
        mapped_calls = [] #: Array[Prism::Node]
        should_exclude = false

        call_nodes.each do |node|
          verdict = classify_unresolved_call(mid, node)
          case verdict
          when :mapped  then mapped_calls << node
          when :exclude then should_exclude = true; break
          # :unrelated — call targets a different class's method, skip
          end
        end

        # An unresolved call the aggressive policy folds into the group is
        # exactly the bet the safe policy refuses: the name goes untouched.
        if should_exclude || (@method_policy == :safe && mapped_calls.any?)
          exclude_mids << mid
        elsif mapped_calls.any?
          @method_rename_mapping.merge_all_by_mid(mid)
          @method_rename_mapping.add_unresolved_sites_for_mid(mid, mapped_calls)
        end
      end
      @method_rename_mapping.exclude_methods_by_mid(exclude_mids) unless exclude_mids.empty?
    end

    def classify_unresolved_call(mid, prism_node)
      # Callers only pass the UNRESOLVED_CALL_NODES shapes, all of which carry
      # a receiver.
      # @type var prism_node: Prism::CallNode | Prism::CallOperatorWriteNode | Prism::CallOrWriteNode | Prism::CallAndWriteNode
      return :mapped unless prism_node.receiver

      target_keys = @oracle.resolved_targets(prism_node, mid)
      return :exclude if target_keys.nil?

      all_mapped = target_keys.all? { |key| @method_rename_mapping.has_method?(key) }
      all_mapped ? :mapped : :unrelated
    end

    public

    def scan_dynamic_method_references(prism_root)
      dynamic_mids = Set.new
      AstUtils.each_node(prism_root) do |node|
        next unless node.is_a?(Prism::CallNode)
        next unless DYNAMIC_DISPATCH_METHODS.include?(node.name)

        @oracle.first_argument_symbols(node).each { |sym| dynamic_mids << sym }
      end
      @method_rename_mapping.exclude_methods_by_mid(dynamic_mids) unless dynamic_mids.empty?
    end

    # send/public_send/__send__ are NOT listed here because TypeProf resolves
    # them as MethodCallBoxes on the target method. resolve_method_calls
    # handles grouping automatically, and MethodRenamer patches the symbol arg.
    DYNAMIC_DISPATCH_METHODS = %i[
      method define_method respond_to? instance_method
    ].freeze

    # A hash/keyword shorthand can pun on a METHOD (`f(unit_label:)` calls
    # unit_label for its value); the one identifier is both the key and the
    # call, so renaming the method would rewrite the key with it. Those
    # methods keep their names.
    def collect_shorthand_pun_methods(prism_root)
      punned = Set.new
      AstUtils.each_node(prism_root) do |node|
        AstUtils.shorthand_pun_values(node).each do |inner|
          punned << inner.name if inner.is_a?(Prism::CallNode)
        end
      end
      @method_rename_mapping.exclude_methods_by_mid(punned) if punned.any?
    end

    VISIBILITY_MODIFIERS = %i[private protected public module_function].freeze

    def collect_visibility_modifier_methods(prism_root)
      excluded_mids = Set.new
      AstUtils.each_node(prism_root) do |node|
        next unless node.is_a?(Prism::CallNode)
        next unless VISIBILITY_MODIFIERS.include?(node.name)

        excluded_mids.merge(AstUtils.symbol_arguments(node))
      end
      @method_rename_mapping.exclude_methods_by_mid(excluded_mids) unless excluded_mids.empty?
    end

    # attr_accessor's setter def is derived from the declared symbol and never
    # registered as a method of its own, so a setter call site type inference
    # missed is invisible to every other exclusion pass — renaming the
    # declaration would strand that site on the old name until the path runs.
    # Find such sites directly and keep their symbols. attr_writer never
    # renames its declaration at all, so a reader sharing its symbol must stay
    # too: renaming the reader side would split the getter from the ivar the
    # writer-defined setter still assigns.
    def collect_attr_write_exclusions(prism_root)
      accessor_owners = Hash.new { |h, k| h[k] = [] } #: Hash[Symbol, Array[MethodRenameMapping::class_key]]
      reader_syms = Set.new
      writer_syms = Set.new
      each_attr_declaration(prism_root, ATTR_DECLARATION_METHODS, require_class_body: false) do |node, cpath, singleton, sym|
        case node.name
        when :attr_accessor then accessor_owners[sym] << [cpath, singleton]
        when :attr_reader then reader_syms << sym
        when :attr_writer then writer_syms << sym
        end
      end

      excluded = writer_syms & (reader_syms | accessor_owners.keys)

      if accessor_owners.any?
        known_setter_sites = Set.new
        accessor_owners.each do |sym, owners|
          owners.each do |cpath, singleton|
            @oracle.each_call_site_key(cpath, singleton, :"#{sym}=") do |key|
              known_setter_sites << key
            end
          end
        end

        AstUtils.each_node(prism_root) do |node|
          write_name = case node
          when Prism::CallNode
            node.name
          when Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
            node.write_name
          else
            next
          end

          next unless AstUtils.setter_def_name?(write_name)

          sym = write_name.to_s.chomp('=').to_sym
          next unless accessor_owners.key?(sym)
          next if known_setter_sites.include?(AstUtils.location_key(node))

          excluded << sym
        end
      end

      @method_rename_mapping.exclude_methods_by_mid(excluded) if excluded.any?
    end

    def collect_alias_undef_methods(prism_root)
      excluded_mids = Set.new
      AstUtils.each_node(prism_root) do |node|
        case node
        when Prism::AliasMethodNode
          excluded_mids << node.new_name.unescaped.to_sym if node.new_name.is_a?(Prism::SymbolNode)
          excluded_mids << node.old_name.unescaped.to_sym if node.old_name.is_a?(Prism::SymbolNode)
        when Prism::UndefNode
          node.names.each do |name|
            excluded_mids << name.unescaped.to_sym if name.is_a?(Prism::SymbolNode)
          end
        end
      end
      @method_rename_mapping.exclude_methods_by_mid(excluded_mids) unless excluded_mids.empty?
    end
  end
end
