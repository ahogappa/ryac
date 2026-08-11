# frozen_string_literal: true

module Ryac
  module Pipeline
    # Base class for all pipeline stages
    # Each stage implements the call(input) -> output pattern
    class Stage
      # Process input and return output
      # @param input [Object] Stage-specific input type
      # @return [Object] Stage-specific output type
      # @raise [StageError] On processing failure
      def call(input)
        raise NotImplementedError, "#{self.class}#call must be implemented"
      end
    end
  end
end
