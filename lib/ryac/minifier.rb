# frozen_string_literal: true

require_relative 'pipeline/stage'
require_relative 'pipeline/data_types'
require_relative 'pipeline/errors'
require_relative 'pipeline/file_collector'
require_relative 'pipeline/concatenator'
require_relative 'pipeline/preprocessor'
require_relative 'pipeline/analyzer'
require_relative 'pipeline/source_patcher'
require_relative 'pipeline/compactor'
require_relative 'pipeline/boolean_shorten'
require_relative 'pipeline/char_shorten'
require_relative 'pipeline/constant_fold'
require_relative 'pipeline/control_flow_simplify'
require_relative 'pipeline/endless_method'
require_relative 'pipeline/paren_optimizer'
require_relative 'pipeline/rename_patcher'
require_relative 'pipeline/constant_aliaser'
require_relative 'pipeline/attr_decl_shorten'
require_relative 'pipeline/variable_renamer'
require_relative 'pipeline/method_renamer'
require_relative 'pipeline/unified_renamer'

module Ryac
  class Minifier
    OPTIMIZE = {
      Pipeline::ControlFlowSimplify => 100,
      Pipeline::EndlessMethod => 90,
      Pipeline::ConstantFold => 50,
      Pipeline::BooleanShorten => 20,
      Pipeline::CharShorten => 10,
      Pipeline::ParenOptimizer => 0,
    }.freeze

    DEFAULT_LEVEL = :stable

    def self.resolve_level(value)
      level = value.to_sym
      return level if STAGES.key?(level)

      raise ArgumentError, "Invalid compress level: #{value} (valid: #{STAGES.keys.join(', ')})"
    end

    ALL_VAR_FEATURES = { features: { keywords: true, ivars: true, cvars: true, gvars: true } }.freeze
    ALL_VAR_WITH_ATTR = { features: { keywords: true, ivars: true, cvars: true, gvars: true, attr_ivars: true } }.freeze

    # The two levels, named for their promise rather than a number.
    #
    # :stable is the boundary the optcarrot test certifies frame-for-frame on
    # a real program: everything up to class, constant and variable renaming,
    # which closed-world analysis can keep sound.
    #
    # :unstable adds method renaming, which a program can defeat by
    # construction — names survive inside strings, eval'd source and computed
    # send targets, out of reach of any static analysis. It is certified by
    # self-hosting and works only when the program plays along.
    #
    # :unstable is a strict superset of :stable: the same stage list with the
    # attr declarations and attr-backed ivars renamed as they are rewritten,
    # plus the method renamer.
    #
    # Finer configurations are not levels: individual steps stay composable
    # by passing an explicit stage list in place of a level name.
    STAGES = {
      stable: [OPTIMIZE, [Pipeline::ConstantAliaser, { rename_classes: true }], [Pipeline::AttrDeclShorten],
               [Pipeline::VariableRenamer, ALL_VAR_FEATURES]],
      # "attrs renamed" is one fact spelled by three co-moving entries:
      # AttrDeclShorten rename_attrs (declarations), attr_ivars (backing
      # ivars) and MethodRenamer (call sites). A composed list must flip
      # all three together or none.
      unstable: [OPTIMIZE, [Pipeline::ConstantAliaser, { rename_classes: true }],
                 [Pipeline::AttrDeclShorten, { rename_attrs: true }],
                 [Pipeline::VariableRenamer, ALL_VAR_WITH_ATTR], [Pipeline::MethodRenamer]],
    }.freeze

    def self.run_stages(code, stages, file_boundaries: [], stdlib_requires: [], rbs_files: {})
      return Pipeline::RenameResult.new(code: code) if stages.empty?

      pre_optimize = [] #: Array[[optimizer_class, Integer]]
      post_optimize = [] #: Array[[optimizer_class, Integer]]
      rename_defs = [] #: Array[untyped]

      stages.each do |entry|
        case entry
        when Hash
          entry.each do |klass, weight|
            (weight > 0 ? pre_optimize : post_optimize) << [klass, weight]
          end
        when Array
          rename_defs << entry
        end
      end

      pre_optimize.sort_by! { |_, w| -w }
      post_optimize.sort_by! { |_, w| -w }

      aliases = ''
      preamble = ''
      result = code

      pre_optimize.each { |klass, _| result = klass.new.call(result) }

      unless rename_defs.empty?
        source = Pipeline::ConcatenatedSource.new(
          content: result,
          file_boundaries: file_boundaries,
          original_size: result.bytesize,
          stdlib_requires: stdlib_requires,
          rbs_files: rbs_files
        )
        rename_result = Pipeline::UnifiedRenamer.new.call(source, rename_defs)
        result = rename_result.code
        aliases = rename_result.aliases
        preamble = rename_result.preamble
      end

      post_optimize.each { |klass, _| result = klass.new.call(result) }

      Pipeline::RenameResult.new(code: result, aliases: aliases, preamble: preamble)
    end

    attr_reader :result

    def initialize
      @file_collector = Pipeline::FileCollector.new
      @concatenator = Pipeline::Concatenator.new
      @preprocessor = Pipeline::Preprocessor.new
    end

    def call(entry_path, level: DEFAULT_LEVEL, project_root: nil, gem_names: [], gem_require_paths: [])
      graph = @file_collector.call(entry_path, project_root: project_root, gem_names: gem_names, gem_require_paths: gem_require_paths)
      source = @concatenator.call(graph)
      source = @preprocessor.call(source)

      result = run_pipeline(source, level)
      build_result(result, source)
    end

    private

    def resolve_level_value(level)
      self.class.resolve_level(level)
    end

    # target_level is a preset name, or — for callers composing their own
    # pipeline out of steps — an explicit stage list.
    def run_pipeline(source, target_level)
      stages = target_level.is_a?(Array) ? target_level : STAGES.fetch(resolve_level_value(target_level))
      compacted = Pipeline::Compactor.new.call(source.content)
      self.class.run_stages(compacted, stages,
        file_boundaries: source.file_boundaries,
        stdlib_requires: source.stdlib_requires,
        rbs_files: source.rbs_files
      )
    end

    def build_result(rename_result, source)
      content = build_output(rename_result.code, source.stdlib_requires, rename_result.preamble)
      verify_parses(content, 'content')
      verify_parses(rename_result.aliases, 'aliases')
      size = content.bytesize

      stats = Pipeline::CompressionStats.new(
        original_size: source.original_size,
        minified_size: size,
        compression_ratio: size.to_f / source.original_size,
        file_count: source.file_boundaries.size
      )

      @result = Pipeline::MinifiedResult.new(
        content: content,
        aliases: rename_result.aliases,
        preamble: rename_result.preamble,
        stats: stats
      )
    end

    def build_output(code, stdlib_requires, preamble = '')
      parts = stdlib_requires.map { |lib| "require \"#{lib}\"" }
      parts << preamble unless preamble.empty?
      parts << code
      parts.join(';')
    end

    # The output of every pipeline permutation must at minimum be valid Ruby.
    # Prism also rejects duplicated parameter names, so a rename that collides
    # inside a signature is caught here, at the stage that produced it.
    def verify_parses(text, label)
      return if text.empty?

      errors = Prism.parse(text).errors
      raise Pipeline::InvalidOutputError.new(label, errors) unless errors.empty?
    end
  end
end
