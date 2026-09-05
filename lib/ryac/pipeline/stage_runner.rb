# frozen_string_literal: true

module Ryac
  module Pipeline
    # The one place that executes a stage list.
    #
    # The list is ordered — phase is position, nothing else. Compaction is
    # the fixed first step. A maximal run of consecutive needs_analysis?
    # stages forms the analysis batch: TypeProf runs once for it, every
    # member collects into one patch pool, the pool is applied in a single
    # splice, and each member's finish then contributes aliases/preamble in
    # list order. A list that would need a second batch implies a second
    # TypeProf run — that is a composition error, and it raises before
    # running anything half-way.
    class StageRunner
      include SourcePatcher

      def initialize(stdlib_requires: [], rbs_files: {}, lazy_files: [], driver: false, marks: [])
        @stdlib_requires = stdlib_requires
        @rbs_files = rbs_files
        @lazy_files = lazy_files
        @driver = driver
        @marks = marks
      end

      def call(code, stage_defs)
        stages = stage_defs.map { |entry| instantiate(entry) }

        batches = stages.chunk_while { |a, b| a.needs_analysis? == b.needs_analysis? }.to_a
        analysis_batches = batches.count { |chunk| chunk.fetch(0).needs_analysis? }
        if analysis_batches > 1
          raise ArgumentError,
                "stage list needs #{analysis_batches} analysis batches; " \
                "TypeProf runs once, so all analysis stages must be consecutive"
        end

        result = Compactor.new.call(code)
        # The compacted text is the dialect every stage downstream assumes.
        # If it does not parse, the Compactor is the culprit — name it here
        # instead of letting whichever stage trips first inherit the blame.
        verify_parses(result, 'compacted')
        aliases = ''
        preamble = ''

        batches.each do |chunk|
          if chunk.fetch(0).needs_analysis?
            result, aliases, preamble = run_analysis_batch(result, chunk)
          else
            chunk.each { |stage| result = stage.call(result) }
          end
        end

        verify_parses(result, 'code')
        verify_parses(aliases, 'aliases')
        RenameResult.new(code: result, aliases: aliases, preamble: preamble)
      end

      private

      def instantiate(entry)
        klass, kwargs = entry
        # A stage entry is data ([class] or [class, kwargs]); configuration
        # becomes constructor state here and nowhere else.
        kwargs ? klass.new(**kwargs) : klass.new
      end

      def run_analysis_batch(code, batch)
        source = ConcatenatedSource.new(
          content: code,
          stdlib_requires: @stdlib_requires,
          rbs_files: @rbs_files,
          lazy_files: @lazy_files,
          driver: @driver,
          marks: @marks
        )
        options = {} #: Hash[Symbol, untyped]
        batch.each { |stage| options.merge!(stage.analysis_options) }
        analysis = Analyzer.new(**options).call(source)

        ctx = StageContext.new(code, analysis.prism_ast, analysis, '', '')
        patches = [] #: Array[patch_entry]
        batch.each { |stage| stage.collect(ctx, patches) }

        result = apply_patches(code, patches)
        ctx.source = result
        batch.each { |stage| stage.finish(ctx) }

        [result, ctx.aliases, ctx.preamble]
      end
    end
  end
end
