# frozen_string_literal: true

module RubyMinify
  # The one place allowed to talk to TypeProf.
  #
  # Everything the renamer needs from type analysis is phrased as a handful
  # of questions — which methods a call can reach, who calls a method, what
  # a receiver is, what a constant resolves to, what a class inherits. The
  # collections compute every lexical fact themselves on the Prism tree and
  # come here only for those questions, so a change in TypeProf's internals
  # breaks this file and nothing else.
  #
  # Answers refer to source positions (location keys) or plain values, never
  # to TypeProf objects.
  class TypeOracle
    def initialize(genv, tp_root)
      @genv = genv
      @tp_root = tp_root
    end

    # Yields every ancestor cpath of the class, including its own.
    # Unresolvable classes yield nothing.
    def each_ancestor_cpath(cpath, singleton, &block)
      @ancestor_cpaths ||= {}
      cached = @ancestor_cpaths[[cpath, singleton]] ||= begin
        list = []
        mod = @genv.resolve_cpath(cpath) rescue nil
        if mod
          @genv.each_superclass(mod, singleton) do |ancestor_mod, _singleton|
            list << ancestor_mod.cpath
          end
        end
        list
      end
      cached.each(&block)
    end

    # Yields [ancestor_cpath, singleton, method_names] along the ancestor
    # chain, own class first — the namespace a new method name must not
    # collide with.
    def each_ancestor_methods(cpath, singleton)
      mod = @genv.resolve_cpath(cpath) rescue nil
      return unless mod

      @genv.each_superclass(mod, singleton) do |ancestor_mod, s|
        names = []
        ancestor_mod.methods[s]&.each_key { |mid| names << mid.to_s }
        yield ancestor_mod.cpath, s, names
      end
    end

    # True when type analysis has any record of the method at all.
    def method_known?(cpath, singleton, mid)
      !resolve_method(cpath, singleton, mid).nil?
    end

    # True when the method has at least one definition in the analyzed source.
    def method_defined?(cpath, singleton, mid)
      entity = resolve_method(cpath, singleton, mid)
      !entity.nil? && entity.defs.size > 0
    end

    def method_call_count(cpath, singleton, mid)
      entity = resolve_method(cpath, singleton, mid)
      entity ? entity.method_call_boxes.size : 0
    end

    # Location keys of every call site that dispatches to the method.
    def each_call_site_key(cpath, singleton, mid)
      entity = resolve_method(cpath, singleton, mid)
      return unless entity

      entity.method_call_boxes.each do |call_box|
        yield AstUtils.location_key(call_box.node)
      end
    end

    # Location keys of the method's definition sites.
    def method_definition_keys(cpath, singleton, mid)
      entity = resolve_method(cpath, singleton, mid)
      return [] unless entity

      entity.defs.to_a.map { |d| AstUtils.location_key(d.node) }
    end

    # One record per call site that dispatches to the method, as plain data:
    #
    #   prism_node       the call in the syntax tree (nil for a super with no
    #                    syntactic call node of its own)
    #   super            true for `super` — dispatch from a subclass override
    #   caller_cpath     the class nesting the call sits in
    #   receiver         whether the call is written with an explicit receiver
    #   keyword_entries  [[symbol_node, value_node], ...] for literal keyword
    #                    arguments, nil when the call passes none
    #   keyword_splat    true when keywords arrive via **splat
    CallerInfo = Struct.new(:prism_node, :super, :caller_cpath, :receiver,
                            :keyword_entries, :keyword_splat, keyword_init: true)

    def each_caller(cpath, singleton, mid)
      entity = resolve_method(cpath, singleton, mid)
      return unless entity

      entity.method_call_boxes.each do |call_box|
        node = call_box.node

        if node.is_a?(TypeProf::Core::AST::SuperNode) ||
           node.is_a?(TypeProf::Core::AST::ForwardingSuperNode)
          yield CallerInfo.new(prism_node: AstUtils.prism_node(node), super: true,
                               caller_cpath: node.lenv.cref.cpath, receiver: false,
                               keyword_entries: nil, keyword_splat: false)
          next
        end

        entries = nil
        splat = false
        kw = node.respond_to?(:keyword_args) ? node.keyword_args : nil
        if kw.is_a?(TypeProf::Core::AST::HashNode)
          splat = kw.keys.any?(&:nil?)
          entries = kw.keys.zip(kw.vals).filter_map do |sym_node, val_node|
            next unless sym_node.is_a?(TypeProf::Core::AST::SymbolNode)
            [AstUtils.prism_node(sym_node), AstUtils.prism_node(val_node)]
          end
        end

        yield CallerInfo.new(prism_node: AstUtils.prism_node(node), super: false,
                             caller_cpath: nil, receiver: !node.recv.nil?,
                             keyword_entries: entries, keyword_splat: splat)
      end
    end

    # The method keys a call could dispatch to, per type inference. nil when
    # inference has no answer at all — distinct from an empty list.
    def resolved_targets(prism_call_node, mid)
      tp_node = tp_call_for(prism_call_node, mid)
      return nil unless tp_node

      keys = []
      tp_node.boxes(:mcall) do |box|
        box.resolve(@genv, nil) do |entity, ty, _mid, _orig_ty|
          next unless entity
          singleton = ty.is_a?(TypeProf::Core::Type::Singleton)
          keys << [ty.mod.cpath, singleton, mid]
        end
      end
      keys.any? ? keys : nil
    end

    # Symbol values inference assigns to the call's first positional argument
    # — how `method(:foo)`-style dynamic references name their target.
    def first_argument_symbols(prism_call_node)
      tp_node = tp_call_for(prism_call_node, prism_call_node.name)
      return [] unless tp_node

      sym_arg = tp_node.positional_args&.first
      ret = sym_arg.ret rescue nil
      return [] unless ret

      ret.types.each_key.filter_map do |ty|
        ty.sym if ty.is_a?(TypeProf::Core::Type::Symbol)
      end
    end

    # True when every inferred type of the call's receiver responds to mid —
    # the safety condition for rewriting the call to a stdlib alias.
    def receiver_responds_to?(prism_call_node, mid)
      every_receiver_base_type(prism_call_node) do |base|
        singleton = base.is_a?(TypeProf::Core::Type::Singleton)
        type_responds_to?(base.mod, singleton, mid)
      end
    end

    # Resolves a constant reference to its fully-qualified path, using type
    # analysis to see through lexical-scope lookup and value constants.
    # nil when the reference is not statically resolvable. Memoized — the
    # counting, external-reference, and precompute passes each ask about the
    # same nodes.
    def resolve_constant_read(prism_node)
      @const_resolution_cache ||= {}
      key = AstUtils.location_key(prism_node)
      return @const_resolution_cache[key] if @const_resolution_cache.key?(key)

      tp_node = tp_const_for(prism_node)
      @const_resolution_cache[key] = tp_node ? resolve_tp_const(tp_node) : nil
    end

    # How many read sites type analysis records for the constant. Can exceed
    # the syntactic count when reads reach it through resolution the text
    # does not show.
    def constant_read_count(cpath)
      entity = begin
        @genv.resolve_const(cpath)
      rescue StandardError
        nil
      end
      entity.respond_to?(:read_boxes) ? entity.read_boxes.size : 0
    end

    # True when every inferred type of the call's receiver is type_name or a
    # subclass — the safety condition for type-specific rewrites like
    # `.empty?` → `=={}` on a Hash.
    def receiver_within_type?(prism_call_node, type_name)
      target_mod = @genv.resolve_cpath([type_name])
      return false unless target_mod

      every_receiver_base_type(prism_call_node) do |base|
        mod_is_or_inherits?(base.mod, target_mod)
      end
    end

    private

    def resolve_method(cpath, singleton, mid)
      @method_cache ||= {}
      key = [cpath, singleton, mid]
      return @method_cache[key] if @method_cache.key?(key)

      @method_cache[key] = begin
        @genv.resolve_method(cpath, singleton, mid)
      rescue StandardError
        nil
      end
    end

    # The shared scaffold of the receiver-safety questions: false unless the
    # receiver has inferred types at all, then the block must hold for every
    # type's base.
    def every_receiver_base_type(prism_call_node)
      recv = tp_call_for(prism_call_node, prism_call_node.name)&.recv
      return false unless recv.respond_to?(:ret) && recv.ret

      types = recv.ret.types
      return false if types.empty?

      types.all? do |ty, _|
        base = ty.base_type(@genv)
        next false unless base.respond_to?(:mod)
        yield base
      end
    end

    def type_responds_to?(mod, singleton, mid)
      @genv.each_superclass(mod, singleton) do |ancestor_mod, s|
        entity = ancestor_mod.methods[s]&.[](mid)
        return true if entity && (entity.exist? || entity.aliases.any?)
      end
      false
    end

    def mod_is_or_inherits?(mod, target)
      return true if mod == target
      @genv.each_superclass(mod, false) do |ancestor, _|
        return true if ancestor == target
      end
      false
    end

    TP_CALL_NODES = [
      TypeProf::Core::AST::CallNode,
      TypeProf::Core::AST::CallReadNode,
      TypeProf::Core::AST::CallWriteNode
    ].freeze

    # TypeProf's node for a call at a given source position. TypeProf answers
    # type questions per node in its own tree; this index is how a question
    # about a Prism node finds its counterpart.
    #
    # Indexed by position *and* method name: a compound write like
    # `self.count += 1` is one position but two TypeProf nodes — a read of
    # `count` and a write of `count=` — and a question about either name has
    # to reach its own node.
    def tp_call_for(prism_node, mid)
      build_tp_indexes
      @tp_calls_by_loc[AstUtils.location_key(prism_node)]&.[](mid)
    end

    # TypeProf's constant-read node at a given source position. Covers plain
    # reads, every level of a qualified chain, and the read half of compound
    # writes (`X ||= 1` reads at the whole expression's position).
    def tp_const_for(prism_node)
      build_tp_indexes
      @tp_consts_by_loc[AstUtils.location_key(prism_node)]
    end

    # Both position indexes come from the same walk; a real run always needs
    # both, so one traversal fills them together.
    def build_tp_indexes
      return if @tp_calls_by_loc

      calls = {}
      consts = {}
      @tp_root.traverse do |event, node|
        next unless event == :enter
        case node
        when *TP_CALL_NODES
          (calls[AstUtils.location_key(node)] ||= {})[node.mid] = node
        when TypeProf::Core::AST::ConstantReadNode
          consts[AstUtils.location_key(node)] = node
        end
      end
      @tp_calls_by_loc = calls
      @tp_consts_by_loc = consts
    end

    # A class/module reference resolves through its own analysis result; a
    # value constant through its definition's location; a qualified chain
    # (Foo::CONST) through its prefix, recursively.
    def resolve_tp_const(node)
      return nil unless node.is_a?(TypeProf::Core::AST::ConstantReadNode)

      static_ret = begin
        node.static_ret
      rescue StandardError
        nil
      end
      return nil unless static_ret.respond_to?(:cpath)
      return static_ret.cpath if static_ret.cpath

      cdef = static_ret.respond_to?(:cdef) ? static_ret.cdef : nil
      if cdef.respond_to?(:defs)
        cdef.defs.each do |d|
          return d.static_cpath if d.respond_to?(:static_cpath) && d.static_cpath
        end
      end

      if node.cbase
        base_cpath = resolve_tp_const(node.cbase)
        return base_cpath + [node.cname] if base_cpath
      end

      nil
    end
  end
end
