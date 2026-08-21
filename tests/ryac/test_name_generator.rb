# frozen_string_literal: true

require_relative '../test_helper'

class TestNameGenerator < Minitest::Test
  def test_first_26_names_are_single_letters
    gen = Ryac::NameGenerator.new
    expected = ('a'..'z').to_a
    actual = 26.times.map { gen.next_name }
    assert_equal expected, actual
  end

  def test_names_27_through_286_are_letter_digit_pairs
    gen = Ryac::NameGenerator.new
    26.times { gen.next_name } # skip a-z

    # First pair: a0
    assert_equal 'a0', gen.next_name
    # Second pair: a1
    assert_equal 'a1', gen.next_name

    # Skip to b0 (after a0..a9 = 10 names, so 8 more)
    8.times { gen.next_name }
    assert_equal 'b0', gen.next_name

    # Skip to z9 (last of length-2)
    # We've consumed: a0, a1, + 8 skipped + b0 = 11 from 260 total
    # z9 is the last one: need 260 - 11 - 1 = 248 more
    248.times { gen.next_name }
    assert_equal 'z9', gen.next_name
  end

  def test_names_after_286_are_three_chars
    gen = Ryac::NameGenerator.new
    # Skip first 26 (a-z) + 260 (a0-z9) = 286
    286.times { gen.next_name }

    # Three-char names follow letter-digit-letter pattern
    assert_equal 'a0a', gen.next_name
    assert_equal 'a0b', gen.next_name
  end

  def test_exclusion_list_skips_names
    gen = Ryac::NameGenerator.new(%w[a b c])
    assert_equal 'd', gen.next_name
    assert_equal 'e', gen.next_name
  end

  def test_prefix_prepends_to_names
    gen = Ryac::NameGenerator.new(prefix: "@")
    assert_equal '@a', gen.next_name
    assert_equal '@b', gen.next_name
  end

  def test_upcase_generates_uppercase_names
    gen = Ryac::NameGenerator.new(upcase: true)
    assert_equal 'A', gen.next_name
    assert_equal 'B', gen.next_name
  end

  def test_upcase_with_multi_char_names
    gen = Ryac::NameGenerator.new(upcase: true)
    26.times { gen.next_name } # skip A-Z
    assert_equal 'A0', gen.next_name
    assert_equal 'A1', gen.next_name
  end

  def test_prefix_and_upcase_combined
    gen = Ryac::NameGenerator.new(prefix: "@@", upcase: true)
    assert_equal '@@A', gen.next_name
  end

  def test_exclusion_compares_final_names
    # The exclusion list holds final names — prefix and case included — so
    # the prefixed families can seed it with what they actually have in hand.
    gen = Ryac::NameGenerator.new(%w[A], upcase: true)
    assert_equal 'B', gen.next_name

    gen = Ryac::NameGenerator.new(%w[@a @b], prefix: '@')
    assert_equal '@c', gen.next_name
  end

  def test_exclusions_accepted_as_a_set
    # Callers hold kept names as Sets; seeding takes them without a copy
    # through to_a.
    gen = Ryac::NameGenerator.new(Set.new(%w[a b]))
    assert_equal 'c', gen.next_name
  end

  def test_no_duplicate_names_in_first_1000
    gen = Ryac::NameGenerator.new
    names = 1000.times.map { gen.next_name }
    assert_equal names.size, names.uniq.size, "Generated duplicate names"
  end

  def test_all_names_are_valid_identifiers
    gen = Ryac::NameGenerator.new
    names = 500.times.map { gen.next_name }
    names.each do |name|
      assert name.match?(/\A[a-z][a-z0-9]*\z/), "Invalid identifier: #{name}"
    end
  end

end
