# frozen_string_literal: true

require_relative 'pipeline/stage'
require_relative 'pipeline/data_types'
require_relative 'pipeline/errors'
require_relative 'pipeline/file_collector'
require_relative 'pipeline/concatenator'
require_relative 'pipeline/analyzer'
require_relative 'pipeline/source_patcher'
require_relative 'pipeline/compactor'
require_relative 'pipeline/boolean_shorten'
require_relative 'pipeline/char_shorten'
require_relative 'pipeline/spelling_shorten'
require_relative 'pipeline/constant_fold'
require_relative 'pipeline/control_flow_simplify'
require_relative 'pipeline/endless_method'
require_relative 'pipeline/paren_optimizer'
require_relative 'pipeline/rename_patcher'
require_relative 'pipeline/stage_runner'
require_relative 'pipeline/constant_aliaser'
require_relative 'pipeline/attr_decl_shorten'
require_relative 'pipeline/variable_renamer'
require_relative 'pipeline/method_renamer'

module Ryac
  class Minifier
    # Stage lists are ordered — phase is list position. The optimizers that
    # run before the rename batch:
    OPTIMIZE_PRE = [
      # ControlFlowSimplify must precede EndlessMethod: a def body has to
      # collapse to a single statement before the def can become endless.
      [Pipeline::ControlFlowSimplify],
      [Pipeline::EndlessMethod],
      [Pipeline::ConstantFold],
      [Pipeline::BooleanShorten],
      [Pipeline::CharShorten],
      [Pipeline::SpellingShorten],
    ].freeze

    # Paren removal reasons about the final spelling of every call, so it
    # runs after all renames.
    OPTIMIZE_POST = [
      [Pipeline::ParenOptimizer],
    ].freeze

    DEFAULT_LEVEL = :stable

    def self.resolve_level(value)
      level = value.to_sym
      return level if STAGES.key?(level)

      raise ArgumentError, "Invalid compress level: #{value} (valid: #{STAGES.keys.join(', ')})"
    end

    ALL_VAR_WITH_ATTR = { features: { keywords: true, ivars: true, cvars: true, gvars: true, attr_ivars: true } }.freeze

    # :unstable is derived from :stable, never hand-copied — the superset
    # law lives here as code. The one switch between them is the method
    # renamer's policy: :safe touches only names whose every caller type
    # inference resolved; :aggressive also takes the bets.
    def self.derive_unstable(stable)
      stable.map { |entry|
        entry[0].equal?(Pipeline::MethodRenamer) ? [Pipeline::MethodRenamer] #: stage_entry
          : entry
      }.freeze
    end

    # The two levels, named for their promise rather than a number.
    #
    # :stable is the boundary the optcarrot test certifies frame-for-frame
    # on a real program: class, constant and variable renaming, plus method
    # renaming under the :safe policy — a group renames only when type
    # inference resolved every caller and no dynamic escape hatch (a string
    # mention, a dynamic-ivar class, an uncalled def) touches its name.
    # "attrs renamed" is one fact spelled by three co-moving switches:
    # AttrDeclShorten rename_attrs (declarations), attr_ivars (backing
    # ivars) and MethodRenamer (call sites) — all three live here together.
    #
    # :unstable switches method renaming to :aggressive, which a program
    # can defeat by construction — names survive inside strings, eval'd
    # source and computed send targets, out of reach of any static
    # analysis. It is certified by self-hosting and works only when the
    # program plays along.
    #
    # Finer configurations are not levels: individual steps stay composable
    # by passing an explicit stage list in place of a level name.
    STABLE_STAGES = [
      *OPTIMIZE_PRE,
      [Pipeline::ConstantAliaser, { rename_classes: true }],
      [Pipeline::AttrDeclShorten, { rename_attrs: true }],
      [Pipeline::VariableRenamer, ALL_VAR_WITH_ATTR],
      [Pipeline::MethodRenamer, { policy: :safe }],
      *OPTIMIZE_POST,
    ].freeze

    STAGES = {
      stable: STABLE_STAGES,
      unstable: derive_unstable(STABLE_STAGES),
    }.freeze

    # code is raw (uncompacted) text — compaction is the runner's fixed
    # first step, so every stage list starts from the same dialect.
    def self.run_stages(code, stages, stdlib_requires: [], rbs_files: {}, lazy_files: [], driver: false)
      Pipeline::StageRunner.new(stdlib_requires: stdlib_requires, rbs_files: rbs_files, lazy_files: lazy_files, driver: driver)
                           .call(code, stages)
    end

    include Pipeline::SourcePatcher

    attr_reader :result

    def initialize
      @file_collector = Pipeline::FileCollector.new
      @concatenator = Pipeline::Concatenator.new
    end

    # driver: the two-file layout (DriverFile) — the program comes back as a
    # library whose lazy regions the driver file's loader runs.
    def call(entry_path, level: DEFAULT_LEVEL, project_root: nil, gem_names: [], gem_require_paths: [], driver: false)
      graph = @file_collector.call(entry_path, project_root: project_root, gem_names: gem_names, gem_require_paths: gem_require_paths)
      source = @concatenator.call(graph, driver: driver)
      # Captured while the boundaries still describe the text; from
      # compaction on they are input provenance, not current positions.
      file_count = source.file_boundaries.size

      result = run_pipeline(source, level)
      build_result(result, source, file_count)
    end

    private

    # target_level is a preset name, or — for callers composing their own
    # pipeline out of steps — an explicit stage list.
    def run_pipeline(source, target_level)
      stages = target_level.is_a?(Array) ? target_level : STAGES.fetch(self.class.resolve_level(target_level))
      self.class.run_stages(source.content, stages,
        stdlib_requires: source.stdlib_requires,
        rbs_files: source.rbs_files,
        lazy_files: source.lazy_files,
        driver: source.driver
      )
    end

    def build_result(rename_result, source, file_count)
      content = build_output(rename_result.code, source.stdlib_requires, rename_result.preamble)
      # code and aliases were verified at the runner's exit; the assembled
      # content is the one string the runner never sees.
      verify_parses(content, 'content')
      size = content.bytesize

      stats = Pipeline::CompressionStats.new(
        original_size: source.original_size,
        minified_size: size,
        compression_ratio: size.to_f / source.original_size,
        file_count: file_count
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
  end
end
