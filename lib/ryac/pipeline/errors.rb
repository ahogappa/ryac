# frozen_string_literal: true

# The superclasses below resolve at load: this edge is what places their
# definitions in front of this file in the concatenated artifact.
require_relative '../errors'

module Ryac
  module Pipeline
    # Base class for input-side pipeline failures: the program being
    # minified (or how it was invoked) is at fault.
    class StageError < Ryac::InputError; end

    # Raised when a required file cannot be found
    class FileNotFoundError < StageError
      attr_reader :path, :required_from, :line

      def initialize(path, required_from: nil, line: nil)
        @path = path
        @required_from = required_from
        @line = line

        message = "File not found: #{path}"
        message += " (required from #{required_from}:#{line})" if required_from && line
        super(message)
      end
    end

    # Raised when a dynamic require or autoload is detected
    class DynamicRequireError < StageError
      attr_reader :path, :line, :expression

      def initialize(path, line:, expression:)
        @path = path
        @line = line
        @expression = expression

        super("Dynamic require at #{path}:#{line}: #{expression}")
      end
    end

    # Raised when a circular dependency is detected in the graph
    class CircularDependencyError < StageError
      attr_reader :cycle

      def initialize(cycle)
        @cycle = cycle

        cycle_str = cycle.map { |p| File.basename(p) }.join(' → ')
        super("Circular dependency: #{cycle_str}")
      end
    end

    # Raised when no files are provided to the minifier
    class NoFilesError < StageError
      def initialize
        super("No files provided. Please provide an entry point file.")
      end
    end

    # Raised when a gem cannot be found or has no Ruby entry file
    class GemNotFoundError < StageError
      attr_reader :gem_name

      def initialize(gem_name)
        @gem_name = gem_name
        super("Gem not found: #{gem_name}")
      end
    end

    # Raised when the pipeline produced output that does not parse. The broken
    # output is a bug in a stage, and failing here names the producer instead
    # of letting the consumer discover it at load time.
    class InvalidOutputError < Ryac::InternalError
      def initialize(label, errors)
        detail = errors.first(3).map { |e|
          "#{e.location.start_line}:#{e.location.start_column}: #{e.message}"
        }.join("; ")
        super("minified #{label} does not parse (#{detail})")
      end
    end

    # Raised when two different names in one scope were assigned the same
    # short name. The output may still parse — `def c(a) = c(a) || d(a)` is
    # valid Ruby — so this cannot be left to a syntax check.
    class RenameCollisionError < Ryac::InternalError
      def initialize(scope, collisions)
        detail = collisions.map { |short, originals|
          "#{originals.join(', ')} -> #{short}"
        }.join("; ")
        super("rename collision in #{scope}: #{detail}")
      end
    end
  end
end
