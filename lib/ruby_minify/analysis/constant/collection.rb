# frozen_string_literal: true

module RubyMinify
  # Assignments that write a bare constant name; the constant lives directly
  # under the lexical nesting.
  CONST_SIMPLE_WRITE_NODES = [
    Prism::ConstantWriteNode,
    Prism::ConstantTargetNode,
    Prism::ConstantOperatorWriteNode,
    Prism::ConstantOrWriteNode,
    Prism::ConstantAndWriteNode
  ].freeze

  # Compound assignments (`X += 1`, `X ||= v`) read the constant as well as
  # write it; both halves count as usage.
  CONST_COMPOUND_WRITE_NODES = [
    Prism::ConstantOperatorWriteNode,
    Prism::ConstantOrWriteNode,
    Prism::ConstantAndWriteNode
  ].freeze

  # Assignments that write through a qualified path (`Foo::X = 1`).
  CONST_PATH_WRITE_NODES = [
    Prism::ConstantPathWriteNode,
    Prism::ConstantPathTargetNode,
    Prism::ConstantPathOperatorWriteNode,
    Prism::ConstantPathOrWriteNode,
    Prism::ConstantPathAndWriteNode
  ].freeze

  # Nodes that constitute a constant read at their own position: plain reads,
  # qualified chains (every level), the read half of compound writes, and a
  # qualified target in multiple assignment (`Foo::A, b = ary`).
  CONST_READ_LIKE_NODES = [
    Prism::ConstantReadNode,
    Prism::ConstantPathNode,
    Prism::ConstantPathTargetNode,
    *CONST_COMPOUND_WRITE_NODES
  ].freeze

  # The fully-qualified path a class/module definition creates, or nil when
  # the written path is not static.
  def class_definition_cpath(node, nesting)
    segments, absolute = Nesting.path_segments(node.constant_path)
    return nil unless segments

    absolute ? segments : nesting + segments
  end

  # The path a constant assignment defines, or nil when it is not static
  # (`self::X`, `expr::X`). A plain path write that repeats the lexical
  # nesting (`Foo::Bar::X = 1` inside module Foo; module Bar) names the same
  # constant the bare write would, so the doubled prefix is dropped; compound
  # and multiple-target writes concatenate as written.
  def const_write_cpath(node, nesting)
    case node
    when *CONST_SIMPLE_WRITE_NODES
      nesting + [node.name]
    when Prism::ConstantPathWriteNode
      segments, absolute = Nesting.path_segments(node.target)
      return nil unless segments
      return segments if absolute

      segments.take(nesting.size) == nesting ? segments : nesting + segments
    else
      target = node.is_a?(Prism::ConstantPathTargetNode) ? node : node.target
      segments, absolute = Nesting.path_segments(target)
      return nil unless segments

      absolute ? segments : nesting + segments
    end
  end

  # The constant path as written, without any resolution — partial when the
  # chain hangs off a dynamic root (`expr::CONST` gives just [:CONST]).
  def syntactic_const_segments(node)
    case node
    when Prism::ConstantPathNode, Prism::ConstantPathTargetNode
      segments = [node.name]
      current = node.parent
      while current.is_a?(Prism::ConstantPathNode)
        segments.unshift(current.name)
        current = current.parent
      end
      segments.unshift(current.name) if current.is_a?(Prism::ConstantReadNode)
      segments
    else
      [node.name]
    end
  end

  # `X = Struct.new(:a)` / `X = Data.define(:a)` with all-symbol arguments is
  # a class definition to type analysis, not a value assignment; such
  # constants are left entirely alone (not registered, counted, or renamed).
  def struct_definition_write?(node)
    return false unless node.is_a?(Prism::ConstantWriteNode) || node.is_a?(Prism::ConstantPathWriteNode)

    value = node.value
    return false unless value.is_a?(Prism::CallNode)

    receiver = value.receiver
    return false unless receiver.is_a?(Prism::ConstantReadNode)
    return false unless (value.name == :new && receiver.name == :Struct) ||
                        (value.name == :define && receiver.name == :Data)

    arguments = value.arguments&.arguments
    return false unless arguments

    arguments.all? { |arg| arg.is_a?(Prism::SymbolNode) }
  end

  def collect_constants(prism_root)
    Nesting.each(prism_root) do |node, nesting, singleton, in_def|
      case node
      when Prism::ClassNode, Prism::ModuleNode
        cpath = class_definition_cpath(node, nesting)
        next unless cpath

        type = node.is_a?(Prism::ClassNode) ? :class : :module
        @constant_mapping.add_definition_with_path(cpath, definition_type: type)
      when *CONST_SIMPLE_WRITE_NODES, *CONST_PATH_WRITE_NODES
        # Skip constants defined inside `class << self` — they live on the
        # metaclass and cannot be accessed as Foo::X, so alias declarations
        # would fail at runtime. (An assignment inside a def body there is a
        # plain assignment and still registers.)
        next if singleton && !in_def
        next if struct_definition_write?(node)

        cpath = const_write_cpath(node, nesting)
        @constant_mapping.add_definition_with_path(cpath, definition_type: :value) if cpath
      end
    end
  end

  def exclude_private_constants(prism_root)
    Nesting.each(prism_root) do |node, nesting, _singleton, _in_def|
      next unless node.is_a?(Prism::CallNode)
      next unless %i[private_constant public_constant].include?(node.name)

      node.arguments&.arguments&.each do |arg|
        next unless arg.is_a?(Prism::SymbolNode)

        @constant_mapping.exclude_path(nesting + [arg.unescaped.to_sym])
      end
    end
  end

  def count_constant_references(prism_root)
    Nesting.each(prism_root) do |node, nesting, _singleton, _in_def|
      case node
      when Prism::ClassNode, Prism::ModuleNode
        cpath = class_definition_cpath(node, nesting)
        @constant_mapping.increment_usage_by_path(cpath) if cpath
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        increment_constant_read_usage(node)
      when *CONST_COMPOUND_WRITE_NODES
        increment_constant_read_usage(node)
        @constant_mapping.increment_usage_by_path(nesting + [node.name])
      when Prism::ConstantWriteNode, Prism::ConstantTargetNode
        next if struct_definition_write?(node)

        @constant_mapping.increment_usage_by_path(nesting + [node.name])
      when Prism::ConstantPathTargetNode
        increment_constant_read_usage(node)
        cpath = const_write_cpath(node, nesting)
        @constant_mapping.increment_usage_by_path(cpath) if cpath
      when *CONST_PATH_WRITE_NODES
        next if struct_definition_write?(node)

        cpath = const_write_cpath(node, nesting)
        @constant_mapping.increment_usage_by_path(cpath) if cpath
      end
    end
  end

  def increment_constant_read_usage(node)
    user_path = resolve_user_defined_cpath(node)
    if user_path
      @constant_mapping.increment_usage_by_path(user_path)
    else
      @constant_mapping.increment_usage(node.name)
    end
  end

  def resolve_user_defined_cpath(node)
    [@oracle.resolve_constant_read(node), syntactic_const_segments(node)].each do |cpath|
      return cpath if cpath && @constant_mapping.user_defined_path?(cpath)
    end
    nil
  end

  # True when the qualified chain is rooted at a plain constant (or written
  # absolute), so its syntactic segments are its complete spelling.
  def complete_const_chain?(node)
    case node
    when Prism::ConstantPathNode, Prism::ConstantPathTargetNode
      current = node.parent
      current = current.parent while current.is_a?(Prism::ConstantPathNode)
      current.nil? || current.is_a?(Prism::ConstantReadNode)
    else
      false
    end
  end

  def required_external_root?(root)
    (@external_require_roots || Set.new).include?(root.to_s)
  end

  # The top-level module names the program's own stdlib/gem requires are
  # expected to provide, by the usual naming convention ("prism" → Prism).
  # A gem that names its module differently just misses the fallback and
  # keeps its full spelling — the conservative direction.
  def external_require_roots(stdlib_requires)
    stdlib_requires.to_set do |path|
      path.split('/').first.split(/[_-]/).map(&:capitalize).join
    end
  end

  # Where a superclass reference lands, for the alias patcher. A qualified
  # path is taken as written; a bare name is meaningful only when it names a
  # user-defined constant in the class's enclosing scope.
  def resolve_superclass_path(superclass_node, class_cpath)
    case superclass_node
    when Prism::ConstantPathNode
      syntactic_const_segments(superclass_node)
    when Prism::ConstantReadNode
      full_path = class_cpath[0...-1] + [superclass_node.name]
      full_path if @constant_mapping&.user_defined_path?(full_path)
    end
  end

  # A closed-world walk sees each textual reference once, but type analysis
  # can record more read sites than the text shows (reads reached through
  # resolution rather than spelling). Take whichever count is higher, so a
  # rename is never judged unprofitable on an undercount.
  def augment_constant_counts_via_oracle
    @constant_mapping.each_user_defined_path do |cpath|
      oracle_count = @oracle.constant_read_count(cpath)
      current_count = @constant_mapping.usage_count_for_path(cpath)
      @constant_mapping.set_usage_count_by_path(cpath, oracle_count) if oracle_count > current_count
    end
  end

  def collect_external_references(prism_root)
    counted_prefix_ids = Set.new
    prefix_counts = Hash.new(0)

    Nesting.each(prism_root) do |node, _nesting, _singleton, _in_def|
      case node
      when *CONST_READ_LIKE_NODES
        next if counted_prefix_ids.include?(node.object_id)

        # Mark the prefix chain so sub-paths are not double-counted.
        current = case node
                  when Prism::ConstantPathNode, Prism::ConstantPathTargetNode then node.parent
                  end
        while current.is_a?(Prism::ConstantPathNode) || current.is_a?(Prism::ConstantReadNode)
          counted_prefix_ids << current.object_id
          current = current.is_a?(Prism::ConstantPathNode) ? current.parent : nil
        end

        full_path = syntactic_const_segments(node)
        resolved_cpath = @oracle.resolve_constant_read(node)
        is_user_defined = @constant_mapping.user_defined_path?(full_path) ||
                          (resolved_cpath && @constant_mapping.user_defined_path?(resolved_cpath))
        # A chain the oracle cannot resolve (no RBS for the gem, say
        # Prism::CallNode) is still a usable alias target when two things
        # hold. The chain must be written out in full from a constant root,
        # so its spelling means the same thing next to the alias declaration
        # as it does here. And the root must belong to a library the program
        # itself requires at top level — the requires are re-emitted ahead of
        # the preamble, so such a root provably exists when the declaration
        # runs. Without that anchor an alias would turn "NameError if this
        # line is ever reached" into "NameError at boot", or capture the
        # wrong constant for a reference that resolves through its nesting
        # at runtime.
        effective_path = resolved_cpath ||
                         (full_path if complete_const_chain?(node) && required_external_root?(full_path.first))
        next unless effective_path && !is_user_defined
        next if effective_path.size < 2
        next if @constant_mapping.has_user_defined_prefix?(full_path)

        prefix = effective_path[0...-1]
        next if @constant_mapping.user_defined_path?(prefix)

        prefix_counts[prefix] += 1
      end
    end

    prefix_counts.each do |prefix, count|
      @constant_mapping.add_external_prefix(prefix, usage_count: count)
    end
  end
end
