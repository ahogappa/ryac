# frozen_string_literal: true

require 'prism'
require 'open3'
require 'rbconfig'
require 'set'

# Static soundness audit for minified output: every constant reference must
# resolve — internally (definitions in the text, under Ruby's lexical,
# ancestor and include rules) or externally (constants the program's own
# requires provide, proven by const_get in a subprocess that loads only
# those requires). A reference that resolves nowhere is a latent NameError:
# it can sit on a path no test executes, armed until a user runs it.
#
# The resolver is deliberately conservative about DEFINITIONS (a multi-
# segment definition registers under every lexical prefix) and strict about
# REFERENCES, so a miss means a genuine "this name exists nowhere".
module ConstantAudit
  SCLASS = :'<sclass>'

  module_function

  # Returns [[path_string, line], ...] for references that resolve nowhere.
  # extra_source (e.g. an aliases file) contributes definitions and is
  # audited too; external lookups load only ruby_source's requires.
  # allow names constants the ORIGINAL program leaves optional (behind a
  # conditional require) — those resolve only where the optional gem happens
  # to be installed, which is the program's own bargain, not minifier damage.
  def unresolved(ruby_source, extra_source: '', allow: [])
    ctx = { defined: Set.new, aliases: {}, ancestors: Hash.new { |h, k| h[k] = [] }, reads: [], requires: [] }
    [ruby_source, extra_source].each do |src|
      next if src.to_s.empty?
      result = Prism.parse(src)
      unless result.errors.none?
        raise "audit input must parse: #{result.errors.map(&:message).join(', ')}"
      end
      collect(result.value, [], ctx)
    end

    pending = ctx[:reads].reject { |read| internally_resolved?(read, ctx) }
    pending = pending.reject { |read| allow.include?(read[:segs].join('::')) }
    return [] if pending.none?

    candidates = pending.map { |read| [read, external_candidates(read, ctx)] }
    known = externally_defined(candidates.flat_map { |_, c| c }, ctx[:requires].uniq)
    candidates
      .reject { |_, c| c.any? { |candidate| known.include?(candidate) } }
      .map { |read, _| [read[:segs].join('::'), read[:line]] }
  end

  def collect(node, stack, ctx)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      segs, absolute = path_segments(node.constant_path)
      return unless segs # non-constant path (e.g. sclass-less oddity) — skip

      define(segs, absolute, stack, ctx)
      add_read(segs[0..-2], absolute, node, stack, ctx) if segs.size > 1

      if node.is_a?(Prism::ClassNode) && node.superclass
        sup_segs, sup_abs = path_segments(node.superclass)
        if sup_segs
          add_read(sup_segs, sup_abs, node.superclass, stack, ctx)
          full = (absolute ? segs : stack.flatten + segs)
          ctx[:ancestors][full] << [sup_segs, sup_abs, lexical_prefixes(stack)]
        else
          collect(node.superclass, stack, ctx)
        end
      end
      collect_children(node.body, absolute ? [segs] : stack + [segs], ctx)

    when Prism::SingletonClassNode
      collect(node.expression, stack, ctx) unless node.expression.is_a?(Prism::SelfNode)
      collect_children(node.body, stack + [[SCLASS]], ctx)

    when Prism::ConstantWriteNode, Prism::ConstantTargetNode,
         Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
      full = stack.flatten + [node.name]
      ctx[:defined] << full
      value = node.respond_to?(:value) ? node.value : nil
      if value
        vsegs, vabs = path_segments(value)
        ctx[:aliases][full] = [vsegs, vabs, lexical_prefixes(stack)] if vsegs
      end
      collect(value, stack, ctx) if value

    when Prism::ConstantPathWriteNode, Prism::ConstantPathTargetNode,
         Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
      segs, absolute = path_segments(node.respond_to?(:target) ? node.target : node)
      if segs
        define(segs, absolute, stack, ctx)
        add_read(segs[0..-2], absolute, node, stack, ctx) if segs.size > 1
      end
      value = node.respond_to?(:value) ? node.value : nil
      collect(value, stack, ctx) if value

    when Prism::ConstantPathNode
      segs, absolute = path_segments(node)
      if segs
        add_read(segs, absolute, node, stack, ctx)
      else
        collect_children(node, stack, ctx) # dynamic root (expr::CONST) — audit the expr
      end

    when Prism::ConstantReadNode
      add_read([node.name], false, node, stack, ctx)

    when Prism::DefinedNode
      # defined?(X) is precisely a query for constants that may not exist.
      nil

    when Prism::CallNode
      if node.receiver.nil? && %i[include prepend].include?(node.name) && node.arguments
        node.arguments.arguments.each do |arg|
          asegs, aabs = path_segments(arg)
          ctx[:ancestors][stack.flatten] << [asegs, aabs, lexical_prefixes(stack)] if asegs
        end
      end
      if node.receiver.nil? && node.name == :require
        arg = node.arguments&.arguments&.[](0)
        ctx[:requires] << arg.unescaped if arg.is_a?(Prism::StringNode)
      end
      collect_children(node, stack, ctx)

    else
      collect_children(node, stack, ctx)
    end
  end

  def collect_children(node, stack, ctx)
    return unless node
    node.compact_child_nodes.each { |child| collect(child, stack, ctx) }
  end

  # A multi-segment definition's true home depends on where its prefix
  # resolves; register it under every lexical prefix so no real definition
  # is ever missing (over-defining can only hide a bug behind an identically
  # spelled path, never invent one).
  def define(segs, absolute, stack, ctx)
    if absolute || stack.none?
      ctx[:defined] << segs
    else
      lexical_prefixes(stack).each { |prefix| ctx[:defined] << prefix + segs }
    end
  end

  def add_read(segs, absolute, node, stack, ctx)
    return if segs.none?
    ctx[:reads] << { segs: segs, absolute: absolute,
                     prefixes: lexical_prefixes(stack), line: node.location.start_line }
  end

  # Module.nesting semantics: each syntactic scope is one entry — `class A::B`
  # contributes [A, B] as a single hop, not two.
  def lexical_prefixes(stack)
    prefixes = [[]]
    flat = []
    stack.each do |entry|
      flat += entry
      prefixes.unshift(flat.dup)
    end
    prefixes
  end

  # Same contract as the pipeline's own path walker; the requiring tests
  # load lib/ryac first, so delegate instead of keeping a copy.
  def path_segments(node)
    Ryac::Nesting.path_segments(node)
  end

  def internally_resolved?(read, ctx)
    return ctx[:defined].include?(read[:segs]) if read[:absolute]

    return true if read[:prefixes].any? { |prefix| ctx[:defined].include?(prefix + read[:segs]) }

    each_ancestor(read[:prefixes][0], ctx) do |ancestor|
      return true if ctx[:defined].include?(ancestor + read[:segs])
    end
    false
  end

  def each_ancestor(cref, ctx, depth = 0)
    return if depth > 8
    ctx[:ancestors][cref].each do |sup_segs, sup_abs, sup_prefixes|
      resolved = if sup_abs
        sup_segs
      else
        sup_prefixes.map { |p| p + sup_segs }.find { |cand| ctx[:defined].include?(cand) }
      end
      next unless resolved
      yield resolved
      each_ancestor(resolved, ctx, depth + 1) { |a| yield a }
    end
  end

  # Candidate absolute spellings for the external check: the path as
  # written, plus the path with its root swapped through internal alias
  # constants (A = Prism makes A::CallNode mean Prism::CallNode).
  def external_candidates(read, ctx, depth = 0)
    return [] if depth > 4
    return [] if read[:segs].include?(SCLASS)

    candidates = [read[:segs].join('::')]
    read[:prefixes].each do |prefix|
      target = ctx[:aliases][prefix + [read[:segs][0]]]
      next unless target
      tsegs, tabs, tprefixes = target
      expanded = { segs: tsegs + read[:segs][1..], absolute: tabs, prefixes: tprefixes }
      candidates += external_candidates(expanded, ctx, depth + 1)
    end
    candidates.uniq
  end

  def externally_defined(candidates, requires)
    candidates = candidates.uniq.select { |c| c.match?(/\A[A-Z][A-Za-z0-9_:]*\z/) }
    return Set.new if candidates.none?

    probe = +''
    requires.each { |lib| probe << "begin;require #{lib.inspect};rescue LoadError;end;" }
    probe << 'STDIN.read.split("\n").each { |p| begin; Object.const_get(p); puts p; rescue NameError, LoadError, ArgumentError; end }'
    # A reference is sound if it resolves in either environment the program
    # can run under. Unbundled, the audited program's lazy requires may name
    # gems outside the test Gemfile that bundler's environment would hide.
    # Bundled, the Gemfile's git-sourced gems are visible where plain
    # require finds something else entirely — Ruby 3.3 ships a pre-Core
    # typeprof as a bundled gem, so TypeProf::Core references prove out
    # only here.
    run = -> { Open3.capture3({ 'RUBYOPT' => nil }, RbConfig.ruby, '-e', probe, stdin_data: candidates.join("\n"))[0] }
    unbundled = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
    bundled = Open3.capture3(RbConfig.ruby, '-e', probe, stdin_data: candidates.join("\n"))[0]
    (unbundled.split("\n") + bundled.split("\n")).to_set
  end
end
