# frozen_string_literal: true

module Ryac
  # Generates sequential short names for variable mangling
  # a, b, ..., z, a0, a1, ..., z9, a0a, a0b, ..., z9z, ...
  class NameGenerator
    LETTERS = ('a'..'z').to_a.freeze
    DIGITS = ('0'..'9').to_a.freeze

    def initialize(additional_excluded = [], prefix: "", upcase: false)
      @index = 0
      @prefix = prefix
      @upcase = upcase
      @excluded = Set.new(additional_excluded) if additional_excluded.any?
    end

    def next_name
      loop do
        name = index_to_name(@index)
        @index += 1
        next if @excluded&.include?(name)
        name = name.upcase if @upcase
        return "#{@prefix}#{name}"
      end
    end

    private

    # Convert index to name using letter-digit alternating scheme:
    # a-z, a0-z9, a0a-z9z, a0a0-z9z9, ...
    def index_to_name(index)
      return LETTERS[index] if index < 26

      index -= 26
      length = 2
      capacity = 26 * 10

      while index >= capacity
        index -= capacity
        length += 1
        capacity *= (length.odd? ? 26 : 10)
      end

      result = ""
      (length - 1).downto(0) do |pos|
        if pos.even?
          result = LETTERS[index % 26] + result
          index /= 26
        else
          result = DIGITS[index % 10] + result
          index /= 10
        end
      end
      result
    end

  end
end
