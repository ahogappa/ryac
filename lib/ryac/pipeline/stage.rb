# frozen_string_literal: true

# Stage#call applies patches at load-definition time via SourcePatcher —
# the module must be concatenated in front of this file.
require_relative 'source_patcher'

module Ryac
  module Pipeline
    # Everything a stage sees while collecting: the current text, its parse,
    # and — inside an analysis batch — the one AnalysisResult. aliases and
    # preamble accumulate finish contributions in list order.
    StageContext = Struct.new(:source, :ast, :analysis, :aliases, :preamble)

    # The one stage contract.
    #
    # A stage declares what it needs (needs_analysis?), whether it must be
    # re-run to a fixed point (fixpoint?), collects byte patches against the
    # context, and contributes aliases/preamble in finish. Parsing, patch
    # application and iteration belong to the runner, never to the stage.
    class Stage
      include SourcePatcher

      # true → member of an analysis batch: the runner parses and runs
      # TypeProf once per maximal run of consecutive analysis stages, and
      # every member collects against that single AnalysisResult.
      def needs_analysis? = false

      # true → the runner re-parses and re-collects until no patches remain.
      def fixpoint? = false

      def collect(ctx, patches)
        raise NotImplementedError, "#{self.class}#collect must be implemented"
      end

      # Post-application contribution (aliases/preamble). Stages with
      # nothing to add do not override this — no identity fakes. Only the
      # runner collects the contribution; the standalone driver below
      # returns text alone.
      def finish(ctx) = nil

      # Driver for a standalone syntactic stage: the per-stage public API.
      def call(input)
        if needs_analysis?
          raise InternalError, "#{self.class} needs analysis; run it through StageRunner"
        end

        source = input
        loop do
          ctx = StageContext.new(source, Prism.parse(source).value, nil, '', '')
          patches = [] #: Array[patch_entry]
          collect(ctx, patches)
          break if patches.none?

          new_source = apply_patches(source, patches)
          break if fixpoint? && new_source == source

          source = new_source
          break unless fixpoint?
        end
        source
      end

      private

      # Analysis stages run only inside the runner's batch, which always
      # supplies the AnalysisResult.
      def analysis(ctx)
        ctx.analysis #: AnalysisResult
      end
    end
  end
end
