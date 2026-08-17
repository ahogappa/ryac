# frozen_string_literal: true

require_relative '../../test_helper'

class TestSpellingShorten < Minitest::Test
  def setup
    @stage = Ryac::Pipeline::SpellingShorten.new
  end

  def test_symbol_array_collapses_when_smaller
    assert_equal 'a=%i[alpha beta gamma]', @stage.call('a=[:alpha,:beta,:gamma]')
  end

  # [:a,:b] and %i[a b] are the same seven bytes — no churn for no gain.
  def test_symbol_array_kept_when_not_smaller
    assert_equal 'a=[:a,:b]', @stage.call('a=[:a,:b]')
  end

  def test_string_array_collapses_with_safe_punctuation
    assert_equal 'C=%w[Style/Not Style/Alias].freeze',
                 @stage.call('C=["Style/Not","Style/Alias"].freeze')
  end

  def test_mixed_array_kept
    assert_equal 'a=[:sym,"str"]', @stage.call('a=[:sym,"str"]')
  end

  def test_unsafe_words_kept
    assert_equal 'a=["has space","b"]', @stage.call('a=["has space","b"]')
    assert_equal 'a=["br[ck]et","other"]', @stage.call('a=["br[ck]et","other"]')
  end

  def test_interpolated_elements_kept
    assert_equal 'a=["x#{y}z","other"]', @stage.call('a=["x#{y}z","other"]')
  end

  def test_english_globals_collapse_to_perl_spellings
    assert_equal 'puts $0;$0="x";p $:;p $"',
                 @stage.call('puts $PROGRAM_NAME;$PROGRAM_NAME="x";p $:;p $"')
  end

  def test_load_path_and_loaded_features_read
    assert_equal 'p $:.size;p $".size',
                 @stage.call('p $LOAD_PATH.size;p $LOADED_FEATURES.size')
  end
end
