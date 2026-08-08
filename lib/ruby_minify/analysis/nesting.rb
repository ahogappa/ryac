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
