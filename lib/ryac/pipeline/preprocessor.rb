# frozen_string_literal: true

require 'rubocop'

module Ryac
  module Pipeline
    # Stage 2.5: RuboCop Preprocessor
    # Applies RuboCop autocorrect to reduce code size before analysis
    class Preprocessor < Stage
      # Deliberately absent, and they must stay that way:
      #
      #   Style/ZeroLengthPredicate
      #     rewrites `x.count == 0` to `x.none?`, which only holds when the
      #     receiver is a collection — `@length_counter.count == 0` against an
      #     ordinary attr_reader raises NoMethodError.
      #   Style/CollectionQuerying
      #     same shape, same failure mode.
      #
      # Style/SendWithLiteralMethodName is listed and stays listed: with the
      # default AllowSend it only rewrites public_send, which cannot reach a
      # private method, so the direct call it produces is equivalent.
      # send/__send__ keep their symbol argument and MethodRenamer patches it.
      #
      # Keep such notes out here: %w[] does not honour `#` comments, so a note
      # written inside the array below silently becomes enabled cop names.
      # test_preprocessor.rb asserts every entry resolves to a real cop.
      COPS = %w[
        Style/RedundantReturn
        Style/RedundantSelf
        Style/SymbolProc
        Style/Proc
        Style/Not
        Style/Strip
        Style/UnlessElse
        Style/EmptyLiteral
        Style/RedundantSortBy
        Style/RedundantArgument
        Style/EmptyElse
        Style/RedundantAssignment
        Style/CollectionCompact
        Style/RedundantFilterChain
        Style/RedundantFreeze
        Style/SlicingWithRange
        Style/RedundantException
        Style/RedundantFetchBlock
        Style/SymbolArray
        Style/WordArray
        Style/SelectByRegexp
        Style/HashSlice
        Style/CombinableDefined
        Style/RedundantConditional
        Style/IfWithBooleanLiteralBranches
        Style/RedundantSelfAssignmentBranch
        Style/RedundantFormat
        Style/RedundantBegin
        Style/RedundantArrayConstructor
        Style/OrAssignment
        Style/SwapValues
        Style/NegativeArrayIndex
        Style/IdenticalConditionalBranches
        Style/ExactRegexpMatch
        Style/SpecialGlobalVars
        Style/Alias
        Style/MinMax
        Style/Sample
        Style/RedundantSort
        Style/SendWithLiteralMethodName
        Naming/BlockForwarding
        Style/ObjectThen
        Style/SuperArguments
        Style/EmptyCaseCondition
        Style/EachForSimpleLoop
        Style/Lambda
        Style/SoleNestedConditional
        Style/IfInsideElse
      ].freeze

      CUSTOM_CONFIG = {
        'Style/SpecialGlobalVars' => { 'EnforcedStyle' => 'use_perl_names' },
        'Style/Lambda' => { 'EnforcedStyle' => 'literal' },
        'Style/SoleNestedConditional' => { 'AllowModifier' => false }
      }.freeze

      # @param source [ConcatenatedSource] From Stage 2
      # @return [ConcatenatedSource] Autocorrected source
      def call(source)
        corrected = rubocop_autocorrect(source.content)
        ConcatenatedSource.new(
          content: corrected,
          file_boundaries: source.file_boundaries,
          original_size: source.original_size,
          stdlib_requires: source.stdlib_requires,
          rbs_files: source.rbs_files
        )
      end

      private

      def rubocop_autocorrect(source_code)
        source = build_processed_source(source_code)
        7.times do
          team = RuboCop::Cop::Team.mobilize(cop_registry, rubocop_config, autocorrect: true, stdin: '')
          report = team.investigate(source)
          break if report.offenses.empty?

          merged = RuboCop::Cop::Corrector.new(source.buffer)
          report.correctors.each do |c|
            next unless c
            begin
              merged.merge!(c)
            rescue Parser::ClobberingError
              # Skip conflicting corrections; they'll be retried next iteration
            end
          end
          corrected = merged.process
          break if corrected == source.buffer.source

          source = build_processed_source(corrected)
        end
        source.buffer.source
      end

      def build_processed_source(code)
        source = RuboCop::ProcessedSource.new(code, RUBY_VERSION.to_f, '(minify).rb')
        source.config = rubocop_config
        source.registry = cop_registry
        source
      end

      def cop_registry
        @cop_registry ||= begin
          global = RuboCop::Cop::Registry.global
          classes = COPS.filter_map { |name| global.find_by_cop_name(name) }
          RuboCop::Cop::Registry.new(classes)
        end
      end

      def rubocop_config
        @rubocop_config ||= begin
          hash = RuboCop::ConfigLoader.default_configuration.to_h.dup
          hash['AllCops'] = hash['AllCops'].merge('DisabledByDefault' => true, 'NewCops' => 'disable')
          COPS.each { |cop| hash[cop] = (hash[cop] || {}).merge('Enabled' => true) }
          CUSTOM_CONFIG.each { |cop, config| hash[cop] = (hash[cop] || {}).merge(config) }
          RuboCop::Config.new(hash)
        end
      end
    end
  end
end
