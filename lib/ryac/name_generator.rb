# frozen_string_literal: true

module Ryac
  # Generates sequential short names for variable mangling
  # a, b, ..., z, a0, a1, ..., z9, a0a, a0b, ..., z9z, ...
  class NameGenerator
    LETTERS = ('a'..'z').to_a.freeze
    DIGITS = ('0'..'9').to_a.freeze

    # A one- or two-character name is as short as this generator's own
    # output; the rename families keep such names untouched, so a second
    # minification pass reassigns nothing and the output is a fixed point.
    KEPT_NAME_MAX = 2

    # additional_excluded holds FINAL names — prefix and case included —
    # which is what every caller has in hand (kept originals, reserved
    # names). Comparing before prefixing would make seeding useless to the
    # prefixed families and force each to re-check by hand.
    def initialize(additional_excluded = [], prefix: "", upcase: false)
      @index = 0
      @prefix = prefix
      @upcase = upcase
      @excluded = Set.new(additional_excluded)
    end

    def next_name
      loop do
        name = index_to_name(@index)
        @index += 1
        name = name.upcase if @upcase
        final = "#{@prefix}#{name}"
        next if @excluded.include?(final)
        return final
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
