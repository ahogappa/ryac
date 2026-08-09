# frozen_string_literal: true

module RubyMinify
  # One classified walk of every constant fact in the tree, shared by
  # definition collection, usage counting, external-reference collection and
  # the analyzer's resolution precompute — so the node-shape case analysis
  # lives in exactly one place. Yields (kind, node, cpath, singleton, in_def):
  #
  #   :class_def  class/module definition; cpath is the path it creates
  #   :read       a constant read at the node's own position (cpath nil)
  #   :write      an assignment defining cpath
  #
  # A compound write (`X ||= 1`) and a qualified target in multiple
  # assignment (`Foo::A, b = ary`) read as well as write, so they yield
  # both a :read and a :write. Writes with no static path and
  # Struct.new/Data.define definitions yield nothing.
  def each_constant_event(prism_root)
    Nesting.each(prism_root) do |node, nesting, singleton, in_def|
      case node
      when Prism::ClassNode, Prism::ModuleNode
        cpath = class_definition_cpath(node, nesting)
        yield :class_def, node, cpath, singleton, in_def if cpath
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        yield :read, node, nil, singleton, in_def
      when Prism::ConstantWriteNode
        next if struct_definition_write?(node)

        yield :write, node, nesting + [node.name], singleton, in_def
      when Prism::ConstantTargetNode
        yield :write, node, nesting + [node.name], singleton, in_def
      when Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
        yield :read, node, nil, singleton, in_def
        yield :write, node, nesting + [node.name], singleton, in_def
      when Prism::ConstantPathTargetNode
        yield :read, node, nil, singleton, in_def
        cpath = qualified_write_cpath(node, nesting)
        yield :write, node, cpath, singleton, in_def if cpath
      when Prism::ConstantPathWriteNode
        next if struct_definition_write?(node)

        cpath = qualified_write_cpath(node.target, nesting, strip_doubled_nesting: true)
        yield :write, node, cpath, singleton, in_def if cpath
      when Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode
        cpath = qualified_write_cpath(node.target, nesting)
        yield :write, node, cpath, singleton, in_def if cpath
      end
    end
  end

  # The fully-qualified path a class/module definition creates, or nil when
  # the written path is not static.
  def class_definition_cpath(node, nesting)
    segments, absolute = Nesting.path_segments(node.constant_path)
    return nil unless segments

    absolute ? segments : nesting + segments
  end

  # The path a qualified assignment target names, or nil when it is not
  # static (`self::X`, `expr::X`). A plain path write that repeats the
  # lexical nesting (`Foo::Bar::X = 1` inside module Foo; module Bar) names
  # the same constant the bare write would, so the doubled prefix is dropped
  # — but only for that form: compound and multiple-target writes
  # concatenate as written, mirroring the previous implementation.
  def qualified_write_cpath(target, nesting, strip_doubled_nesting: false)
    segments, absolute = Nesting.path_segments(target)
    return nil unless segments
    return segments if absolute
    return segments if strip_doubled_nesting && segments.take(nesting.size) == nesting

    nesting + segments
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
    each_constant_event(prism_root) do |kind, node, cpath, singleton, in_def|
      case kind
      when :class_def
        type = node.is_a?(Prism::ClassNode) ? :class : :module
        @constant_mapping.add_definition_with_path(cpath, definition_type: type)
      when :write
        # Skip constants defined inside `class << self` — they live on the
        # metaclass and cannot be accessed as Foo::X, so alias declarations
        # would fail at runtime. (An assignment inside a def body there is a
        # plain assignment and still registers.)
        next if singleton && !in_def

        @constant_mapping.add_definition_with_path(cpath, definition_type: :value)
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
    each_constant_event(prism_root) do |kind, node, cpath, _singleton, _in_def|
      case kind
      when :class_def, :write
        @constant_mapping.increment_usage_by_path(cpath)
      when :read
        increment_constant_read_usage(node)
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

    each_constant_event(prism_root) do |kind, node, _cpath, _singleton, _in_def|
      next unless kind == :read
      next if counted_prefix_ids.include?(node.object_id)

      mark_chain_prefixes(node, counted_prefix_ids)
      prefix = external_prefix_for(node)
      prefix_counts[prefix] += 1 if prefix
    end

    prefix_counts.each do |prefix, count|
      @constant_mapping.add_external_prefix(prefix, usage_count: count)
    end
  end

  # Mark the reference's prefix chain so sub-paths are not counted again as
  # references of their own.
  def mark_chain_prefixes(node, counted_prefix_ids)
    current = case node
              when Prism::ConstantPathNode, Prism::ConstantPathTargetNode then node.parent
              end
    while current.is_a?(Prism::ConstantPathNode) || current.is_a?(Prism::ConstantReadNode)
      counted_prefix_ids << current.object_id
      current = current.is_a?(Prism::ConstantPathNode) ? current.parent : nil
    end
  end

  # The external prefix this reference should be counted under, or nil when
  # it has none: the reference must not touch the project's own namespace,
  # and must either resolve through type analysis or — the fallback for gems
  # with no RBS — be spelled in full from a root that one of the program's
  # own top-level requires provides. The requires are re-emitted ahead of
  # the preamble, so such a root provably exists when the alias declaration
  # runs; without that anchor an alias would turn "NameError if this line is
  # ever reached" into "NameError at boot", or capture the wrong constant
  # for a reference that resolves through its nesting at runtime.
  def external_prefix_for(node)
    full_path = syntactic_const_segments(node)
    resolved_cpath = @oracle.resolve_constant_read(node)
    return nil if @constant_mapping.user_defined_path?(full_path)
    return nil if resolved_cpath && @constant_mapping.user_defined_path?(resolved_cpath)

    effective_path = resolved_cpath ||
                     (full_path if complete_const_chain?(node) && required_external_root?(full_path.first))
    return nil unless effective_path
    return nil if effective_path.size < 2
    return nil if @constant_mapping.has_user_defined_prefix?(full_path)

    prefix = effective_path[0...-1]
    return nil if @constant_mapping.user_defined_path?(prefix)

    prefix
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
    (@boot_constant_roots || Set.new).include?(root)
  end

  # The top-level constants that exist when the minified program boots,
  # before any of its own code runs: Ruby's core names plus whatever its
  # top-level requires provide. Asking a fresh interpreter is what makes
  # this exact — no naming-convention guessing, and no contamination from
  # the constants the minifier process itself happens to have loaded.
  # nil when the probe fails, so callers can fall back conservatively.
  def boot_constant_roots(stdlib_requires)
    key = stdlib_requires.sort
    return BOOT_CONSTANT_CACHE[key] if BOOT_CONSTANT_CACHE.key?(key)

    BOOT_CONSTANT_CACHE[key] = probe_boot_constants(stdlib_requires)
  end

  BOOT_CONSTANT_CACHE = {} # : Hash[Array[String], Set[Symbol]?]

  # The probe must run outside the minifier's bundler context: with it, the
  # subprocess boots bundler, bundler evaluates the analyzed project's
  # gemspec-style Gemfile, and the program's own constants leak into the
  # "exists at boot" answer — under self-hosting, RubyMinify itself.
  def probe_boot_constants(stdlib_requires)
    requires = stdlib_requires.map { |r| "begin;require #{r.dump};rescue LoadError;end" }.join(';')
    script = "#{requires};puts Object.constants"
    popen = -> { IO.popen([{ 'RUBYOPT' => nil }, RbConfig.ruby, '-e', script], &:read) }
    out = defined?(Bundler) ? Bundler.with_unbundled_env(&popen) : popen.call
    Process.last_status&.success? ? out.split.map(&:to_sym).to_set : nil
  rescue StandardError
    nil
  end
end
