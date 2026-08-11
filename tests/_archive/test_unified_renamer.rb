# frozen_string_literal: true

require_relative 'test_helper'

class TestUnifiedRenamer < Minitest::Test
  include MinifyTestHelper

  UNIFIED_CODE = <<~RUBY
    class MyClass
      def my_method(my_pos, my_kw:)
        @my_ivar = my_pos + my_kw
        puts @my_ivar
      end
    end
    MyClass.new.my_method(1, my_kw: 2)
    MyClass.new.my_method(3, my_kw: 4)
    MyClass.new.my_method(5, my_kw: 6)
  RUBY

  def group
    @group ||= begin
      source = Ryac::Pipeline::ConcatenatedSource.new(
        content: UNIFIED_CODE,
        file_boundaries: [],
        original_size: UNIFIED_CODE.bytesize,
        stdlib_requires: [],
        rbs_files: {}
      )
      preprocessor = Ryac::Pipeline::Preprocessor.new
      source = preprocessor.call(source)

      optimized = Ryac::Pipeline::Compactor.new.call(source.content)
      Ryac::Minifier::OPTIMIZE[0...-1].each { |k| optimized = k.new.call(optimized) }
      optimized = Ryac::Pipeline::ParenOptimizer.new.call(optimized)

      {
        l2: run_sequential_stages(optimized, {}, 2),
        l3: run_sequential_stages(optimized, {}, 3),
        l5: run_sequential_stages(optimized, {}, 5),
      }
    end
  end

  # --- L2: only constant aliasing ---

  def test_l2_does_not_rename_variables
    assert_equal true, group[:l2].code.include?("my_pos")
    assert_equal true, group[:l2].code.include?("@my_ivar")
  end

  def test_l2_does_not_rename_methods
    assert_equal true, group[:l2].code.include?("my_method")
  end

  # --- L3: constants + variables (no ivars, no methods) ---

  def test_l3_renames_positional_args
    assert_equal false, group[:l3].code.include?("my_pos")
  end

  def test_l3_renames_keywords
    assert_equal false, group[:l3].code.include?("my_kw")
  end

  def test_l3_preserves_ivars
    assert_equal true, group[:l3].code.include?("@my_ivar")
  end

  def test_l3_preserves_methods
    assert_equal true, group[:l3].code.include?("my_method")
  end

  # --- L5: all three stages ---

  def test_l5_renames_methods
    assert_equal false, group[:l5].code.include?("my_method")
  end

  def test_l5_renames_ivars
    assert_equal false, group[:l5].code.include?("@my_ivar")
  end

  def test_l5_renames_variables
    assert_equal false, group[:l5].code.include?("my_pos")
  end

  # --- Exact output verification ---

  def test_l3_exact_output
    assert_equal "class MyClass;def my_method(b,a:);@my_ivar=b+a;puts @my_ivar;end;end;MyClass.new.my_method(1,a:2);MyClass.new.my_method(3,a:4);MyClass.new.my_method(5,a:6)", group[:l3].code
  end

  def test_l5_exact_output
    assert_equal "class MyClass;def a(b,a:);@a=b+a;puts @a;end;end;MyClass.new.a(1,a:2);MyClass.new.a(3,a:4);MyClass.new.a(5,a:6)", group[:l5].code
  end
end
