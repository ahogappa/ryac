# frozen_string_literal: true

module Ryac
  module Pipeline
    # Runs TypeProf once and collects patches from all rename stages.
    # Each stage is independent — UnifiedRenamer has no knowledge of
    # what any individual stage does or how stages relate to each other.
    # It only relies on two class-method protocols:
    #   klass.collect_patches_from(prism_ast, patches, analysis, kwargs)
    #   klass.postprocess(result, analysis, aliases_str, preamble_str) → [result, aliases_str, preamble_str]
    class UnifiedRenamer
      include RenamePatcher

      def call(source, stage_defs)
        return RenameResult.new(code: source.content) if stage_defs.empty?

        analysis = Pipeline::Analyzer.new.call(source)

        if analysis.constant_mapping
          rename_classes = stage_defs.any? { |_, kwargs| kwargs&.dig(:rename_classes) }
          generator = NameGenerator.new([], upcase: true)
          analysis.constant_mapping.assign_short_names(generator, skip_class_modules: !rename_classes)
        end

        prism_ast = analysis.prism_ast
        patches = []

        stage_defs.each do |klass, kwargs|
          klass.collect_patches_from(prism_ast, patches, analysis, kwargs)
        end

        result = apply_patches(source.content, patches)
        aliases_str = ''
        preamble_str = ''

        stage_defs.each do |klass, _kwargs|
          result, aliases_str, preamble_str = klass.postprocess(result, analysis, aliases_str, preamble_str)
        end

        RenameResult.new(code: result, aliases: aliases_str, preamble: preamble_str)
      end
    end
  end
end
