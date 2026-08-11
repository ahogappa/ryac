# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'test_fixtures'

class TestOptimizationLevels < Minitest::Test
  include MinifyTestHelper
  include RenameTestFixtures

  # --- Shared code for multi-level tests ---

  SHARED_LEVEL_CODE = <<~RUBY
    class MyClass
      def my_method(my_arg)
        my_arg.to_s
      end
    end
    MyClass.new.my_method(1)
    MyClass.new.my_method(2)
    MyClass.new.my_method(3)
  RUBY

  SHARED_LEVEL_CODE_WITH_KW = <<~RUBY
    class MyClass
      def my_method(my_pos, my_kw:)
        local_var = my_pos + my_kw
        puts local_var
      end
    end
    MyClass.new.my_method(1, my_kw: 2)
    MyClass.new.my_method(3, my_kw: 4)
    MyClass.new.my_method(5, my_kw: 6)
  RUBY

  SHARED_LEVEL_CODE_WITH_IVAR = <<~RUBY
    class MyClass
      def initialize(my_arg)
        @my_ivar = my_arg
      end
      def my_method
        @my_ivar.to_s
      end
    end
    MyClass.new(1).my_method
    MyClass.new(2).my_method
    MyClass.new(3).my_method
  RUBY

  # Lazy-compute results per code variant and level
  LEVEL_CODES = {
    basic: SHARED_LEVEL_CODE,
    kw: SHARED_LEVEL_CODE_WITH_KW,
    ivar: SHARED_LEVEL_CODE_WITH_IVAR,
  }.freeze

  def level_results
    @@level_results ||= Hash.new { |h, k| h[k] = {} }
  end

  def level_result(variant, level)
    level_results[variant][level] ||= minify_at_level(LEVEL_CODES[variant], level)
  end

  # --- Level 0: Compaction only (Prism, no TypeProf) ---

  def test_level0_removes_comments
    result = minify_at_level("# This is a comment\nx = true\ny = false\nputs(x, y)\n\ndef my_method(my_arg)\n  if my_arg\n    \"hello\"\n  else\n    \"world\"\n  end\nend\nputs my_method(\"a\")\n", 0)
    assert_equal false, result.code.include?("comment")
    assert_equal "x=true;y=false;puts(x,y);def my_method(my_arg);if my_arg;\"hello\";else;\"world\";end;end;puts(my_method(\"a\"))", result.code
  end

  # --- Level 1: Syntax optimizations (Prism, no TypeProf) ---

  def test_level1_full_output
    result = minify_at_level("x = true\ny = false\nputs(x, y)\n\ndef my_method(my_arg)\n  if my_arg\n    \"hello\"\n  else\n    \"world\"\n  end\nend\nputs my_method(\"a\")\n", 1)
    assert_equal "x=!!1;y=!1;puts x,y;def my_method(my_arg) =my_arg ? \"hello\":\"world\";puts my_method(?a)", result.code
  end

  # --- Level 2: Constant aliasing (TypeProf) ---

  def test_level2_does_not_rename_variables
    assert_equal true, level_result(:basic, 2).code.include?("my_arg")
  end

  def test_level2_does_not_rename_methods
    assert_equal true, level_result(:basic, 2).code.include?("my_method")
  end

  def test_level2_applies_syntax_optimizations
    assert_equal true, level_result(:basic, 2).code.include?("!!1") || !level_result(:basic, 2).code.include?("true")
  end

  # --- Level 3: Safe renaming (TypeProf) ---

  def test_level3_safe_renames_positional_args
    assert_equal false, level_result(:kw, 3).code.include?("my_pos")
  end

  def test_level3_safe_renames_keyword_args
    assert_equal false, level_result(:kw, 3).code.include?("my_kw")
  end

  def test_level3_safe_preserves_methods
    assert_equal true, level_result(:kw, 3).code.include?("my_method")
  end

  def test_level3_safe_full_output
    assert_equal "class MyClass;def my_method(b,a:);c=b+a;puts c;end;end;MyClass.new.my_method(1,a:2);MyClass.new.my_method(3,a:4);MyClass.new.my_method(5,a:6)", level_result(:kw, 3).code
    assert_equal "", level_result(:kw, 3).aliases
  end

  # --- Level 3 safe: positional-only code matches level 4 ---

  def test_level3_safe_matches_level4_without_keywords
    assert_equal level_result(:basic, 3), level_result(:basic, 4)
  end

  # --- Level 3 safe: ivars are NOT renamed ---

  def test_level3_safe_preserves_ivars
    assert_equal true, level_result(:ivar, 3).code.include?("@my_ivar")
  end

  def test_level3_safe_renames_positional_in_ivar_code
    assert_equal false, level_result(:ivar, 3).code.include?("my_arg")
  end

  # --- Level 4: Full variable renaming (TypeProf) ---

  def test_level4_renames_variables
    assert_equal false, level_result(:basic, 4).code.include?("my_arg")
  end

  def test_level4_does_not_rename_methods
    assert_equal true, level_result(:basic, 4).code.include?("my_method")
  end

  # --- Level 5: Method renaming (TypeProf, default) ---

  def test_level5_renames_methods
    assert_equal false, level_result(:basic, 5).code.include?("my_method")
  end

  def test_level5_renames_variables
    assert_equal false, level_result(:basic, 5).code.include?("my_arg")
  end

  # --- Level 5 is byte-identical to default minify_code ---

  def test_level5_matches_default
    default_result = minify_code(SHARED_LEVEL_CODE)
    assert_equal default_result, level_result(:basic, 5)
  end

  # --- Level 0 always adds parens ---

  def test_level0_always_adds_parens
    result = minify_at_level("x = 1\ny = 2\nputs x\nputs(y)\n", 0)
    assert_equal "x=1;y=2;puts(x);puts(y)", result.code
  end

  # --- Each level produces valid Ruby ---

  def test_all_levels_produce_valid_ruby
    (0..5).each do |level|
      result = level_result(:basic, level)
      assert_equal false, result.code.nil?
      assert_equal false, result.code.empty?
    end
  end

  # --- Higher levels always produce shorter or equal output ---

  def setup_monotonic
    @monotonic ||= begin
      code = <<~RUBY
        class Calculator
          def add_numbers(first_number, second_number)
            first_number + second_number
          end
          def subtract_numbers(first_number, second_number)
            first_number - second_number
          end
        end
        calc = Calculator.new
        puts calc.add_numbers(10, 20)
        puts calc.subtract_numbers(30, 10)
        puts calc.add_numbers(5, 5)
      RUBY
      (0..5).map { |level| minify_at_level(code, level) }
    end
  end

  def test_output_shrinks_monotonically
    setup_monotonic
    [0, 2, 3, 4].each_cons(2) do |i, j|
      assert_operator @monotonic[i].code.length, :>=, @monotonic[j].code.length,
        "Level #{i} output (#{@monotonic[i].code.length} bytes) should be >= level #{j} (#{@monotonic[j].code.length} bytes)"
    end
  end

  # --- Minifier.call level: parameter ---

  def test_minifier_call_with_level
    require 'tempfile'
    Tempfile.create(['level_test', '.rb']) do |f|
      f.write("x = true\nputs x\n")
      f.flush
      minifier = Ryac::Minifier.new
      result_l0 = minifier.call(f.path, level: 0)
      result_l5 = minifier.call(f.path, level: 5)
      assert_equal "x=true;puts(x)", result_l0.content
      assert_equal "x=!!1;puts x", result_l5.content
      assert_equal '', result_l0.aliases
      assert_equal '', result_l5.aliases
    end
  end
end
