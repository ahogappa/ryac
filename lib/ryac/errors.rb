# frozen_string_literal: true

# The error hierarchy lives in its own required file, not in ryac.rb:
# superclass references execute at load, and the concatenated self-host
# artifact places dependencies first and the root file's own body last —
# a class defined in the root body can never be a parent for a class
# defined in a required file.
module Ryac
  class Error < StandardError; end

  # The program being minified is at fault — fix the input.
  class InputError < Error; end

  # ryac itself is at fault — please report it.
  class InternalError < Error; end

  # The input uses a construct minification cannot handle.
  class MinifyError < InputError; end

  # The input does not parse. Carries the coordinates of the first error.
  class SyntaxError < InputError
    attr_reader :path, :line, :column

    def initialize(message, path: nil, line: nil, column: nil)
      @path = path
      @line = line
      @column = column
      message = "#{path}:#{line}:#{column}: #{message}" if path
      super(message)
    end
  end
end
