# frozen_string_literal: true

require_relative '../../test_helper'

# The :safe method-rename policy renames only groups whose every caller
# type inference resolved. The aggressive policy's bets — folding
# unresolved calls and blind defs into groups, renaming names that only
# strings mention — are exactly what it refuses.
class TestSafeMethodPolicy < Minitest::Test
  include MinifyTestHelper

  SAFE_STAGES = Ryac::Minifier::STAGES[:unstable].map { |entry|
    entry[0].equal?(Ryac::Pipeline::MethodRenamer) ? [entry[0], { policy: :safe }] : entry
  }.freeze

  def minify_safe(code)
    result = Ryac::Minifier.run_stages(code, SAFE_STAGES)
    assert_output_preserved(code, result)
    result
  end

  # eval and send-by-string dispatch from strings the renamer cannot
  # rewrite: a name spelled inside any string literal survives, while its
  # unmentioned neighbors still rename.
  def test_name_mentioned_in_string_literal_survives
    code = <<~RUBY
      class Ops
        def fetch_word = 1
        def store_word = 2
        def helper = fetch_word + store_word
      end
      o = Ops.new
      puts o.helper
      puts eval("o.fetch_word")
    RUBY
    result = minify_safe(code)
    assert_equal 'class A;def fetch_word =1;def a =2;def b =fetch_word+a;end;o=A.new;puts o.b;puts eval("o.fetch_word")',
                 result.code
  end

  # A def no resolved call reaches is either dead or called from outside
  # the program — the safe policy keeps its name either way. The resolved
  # neighbors rename as usual.
  def test_uncalled_def_keeps_name
    code = <<~RUBY
      class Api
        def external_hook = 99
        def internal_step = 21
        def doubled = internal_step * 2
      end
      puts Api.new.doubled
    RUBY
    result = minify_safe(code)
    assert_equal 'class A;def external_hook =99;def a =21;def b =a*2;end;puts A.new.b',
                 result.code
  end
end
