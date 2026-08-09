# frozen_string_literal: true

module RubyMinify
  # Closed-world walk of the Prism tree with the class/module nesting tracked.
  #
  # The nesting is a lexical fact: `class B::C` under [:M, :A] defines
  # [:M, :A, :B, :C] — verified against TypeProf, which concatenates the
  # written path onto the enclosing nesting exactly like this rather than
  # resolving `B` first. Defs and `class << self` do not change it. The one
  # thing that cannot be computed here is a dynamic path (`class self::X`,
  # `class << other`); those bodies are not descended into, which errs on the
  # side of leaving their contents unrenamed.
  module Nesting
    module_function

    # Yields every node together with the enclosing [cpath, singleton, in_def]
    # — singleton is true inside `class << self`, in_def inside a method body.
    def each(root, &block)
      walk(root, [], false, false, &block)
    end

    # Yields meta-style declarations (`attr_reader :a` / `include M`) under
    # the conditions type analysis recognizes them: a bare call in statement
    # position directly in a class or module body (or `class << self`),
    # outside any def. Passing loose: true drops everything but the bare-call
    # requirement — for consumers where over-matching is the safe direction.
    def each_meta_call(root, names, loose: false)
      if loose
        each(root) do |node, cpath, singleton, _in_def|
          next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && names.include?(node.name)

          yield node, cpath, singleton
        end
      else
        each(root) do |node, cpath, singleton, in_def|
          next unless node.is_a?(Prism::StatementsNode)
          next if in_def
          # any? rather than empty?: the type-dependent empty? transform does
          # not reach a fixed point on this code under self-hosting.
          next unless cpath.any? || singleton

          node.body.each do |child|
            next unless child.is_a?(Prism::CallNode) && child.receiver.nil? && names.include?(child.name)

            yield child, cpath, singleton
          end
        end
      end
    end

    # Yields every method definition with its [cpath, singleton, name] key:
    # the receiver form folded in (`def self.x` and defs inside `class <<
    # self` are singleton; `def Foo.x` defines on Foo wherever it lexically
    # sits), so every collection computes method identity the same way.
    def each_method_definition(root)
      each(root) do |node, cpath, sclass_singleton, _in_def|
        next unless node.is_a?(Prism::DefNode)

        singleton = sclass_singleton || !node.receiver.nil?
        key_cpath = cpath
        receiver = node.receiver
        if receiver && !receiver.is_a?(Prism::SelfNode)
          segments, _absolute = path_segments(receiver)
          key_cpath = segments if segments
        end
        yield node, [key_cpath, singleton, node.name].freeze
      end
    end

    # The path a class/module definition appends to the enclosing nesting.
    # Returns [segments, absolute] — absolute when written `class ::X` —
    # or nil when the path is not statically known.
    def path_segments(constant_path)
      segments = []
      current = constant_path
      while current.is_a?(Prism::ConstantPathNode)
        segments.unshift(current.name)
        current = current.parent
      end

      case current
      when Prism::ConstantReadNode
        [segments.unshift(current.name), false]
      when nil
        [segments, true]
      end
    end

    def walk(node, cpath, singleton, in_def, &block)
      return unless node.is_a?(Prism::Node)

      yield node, cpath, singleton, in_def

      case node
      when Prism::ClassNode, Prism::ModuleNode
        # The name path is walked too: its segments are constant references
        # in their own right (counted and aliased like any other).
        walk(node.constant_path, cpath, singleton, in_def, &block)
        walk(node.superclass, cpath, singleton, in_def, &block) if node.is_a?(Prism::ClassNode) && node.superclass
        segments, absolute = path_segments(node.constant_path)
        return unless segments

        inner = absolute ? segments : cpath + segments
        walk(node.body, inner, false, false, &block)
      when Prism::SingletonClassNode
        walk(node.expression, cpath, singleton, in_def, &block)
        return unless node.expression.is_a?(Prism::SelfNode)

        walk(node.body, cpath, true, in_def, &block)
      when Prism::DefNode
        # The receiver of `def Foo.bar` is deliberately not walked: type
        # analysis has no nodes there, and every renamer that cares reads
        # node.receiver off the def itself.
        walk(node.parameters, cpath, singleton, true, &block)
        walk(node.body, cpath, singleton, true, &block)
      else
        node.compact_child_nodes.each { |child| walk(child, cpath, singleton, in_def, &block) }
      end
    end
  end
end
