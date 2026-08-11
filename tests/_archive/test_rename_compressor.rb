# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tempfile'
require 'rbconfig'
require_relative 'test_helper'

# Test that pipeline rename stages produce identical output to the old rebuild-based pipeline
class TestRenameCompressor < Minitest::Test
  include MinifyTestHelper

  # All test code combined into one block to minimize TypeProf inits
  COMPRESSOR_TEST_CODE = <<~RUBY
    module MyModule
      class MyClass
        def run
          MyClass.new
          MyClass.new
        end
      end
    end

    module Outer
      module Inner
        class DeepClass
          def use
            Outer::Inner::DeepClass.new
            Outer::Inner::DeepClass.new
          end
        end
      end
    end

    module Config
      VALUE = 42
      OTHER = VALUE + VALUE + VALUE
    end

    def calculate(x, y)
      result = x + y
      result * 2
    end
    puts calculate(3, 4)

    def greet(name:, greeting: "Hello")
      puts "\#{greeting}, \#{name}!"
    end
    greet(name: "World")

    class Foo
      def initialize
        @value = 0
      end
      def increment
        @value += 1
        @value
      end
    end
    f = Foo.new
    f.increment
    puts f.increment

    class Calculator
      def calculate(value)
        value * 2
      end
      def process(input)
        calculate(input) + calculate(input + 1)
      end
    end
    c = Calculator.new
    puts c.process(5)

    class MyClass2
      def my_method(my_arg)
        my_arg.to_s
      end
    end
    MyClass2.new.my_method(1)
    MyClass2.new.my_method(2)
    MyClass2.new.my_method(3)

    class MyClass3
      def my_method(my_pos, my_kw:)
        local_var = my_pos + my_kw
        puts local_var
      end
    end
    MyClass3.new.my_method(1, my_kw: 2)
    MyClass3.new.my_method(3, my_kw: 4)
    MyClass3.new.my_method(5, my_kw: 6)

    class MyClass4
      def initialize(my_arg)
        @my_ivar = my_arg
      end
      def my_method
        @my_ivar.to_s
      end
    end
    MyClass4.new(1).my_method
    MyClass4.new(2).my_method
    MyClass4.new(3).my_method

    class Calculator2
      def add_numbers(first_number, second_number)
        first_number + second_number
      end
      def subtract_numbers(first_number, second_number)
        first_number - second_number
      end
    end
    calc = Calculator2.new
    puts calc.add_numbers(10, 20)
    puts calc.subtract_numbers(30, 10)
    puts calc.add_numbers(5, 5)

    class Person
      attr_reader :first_name, :last_name
      def initialize(first, last)
        @first_name = first
        @last_name = last
      end
      def full_name
        "\#{first_name} \#{last_name}"
      end
    end
    p_obj = Person.new("John", "Doe")
    puts p_obj.full_name

    [1, 2, 3].each do |item|
      puts item
    end

    def make_hash(name, age)
      { name: name, age: age }
    end
    puts make_hash("Alice", 30).inspect

    for item in [1, 2, 3]
      puts item
    end

    begin
      raise "error"
    rescue => error
      puts error.message
    end

    def foo_rescue
      begin
        raise "test"
      rescue RuntimeError => err
        puts err.message
      end
    end
    foo_rescue

    def foo_hash(name_arg)
      { name_arg: }
    end
    puts foo_hash(1).inspect

    class Counter
      @@count = 0
      def initialize
        @value = 0
        @@count += 1
      end
      def increment
        @value += 1
      end
      def self.count_value
        @@count
      end
    end
    ctr = Counter.new
    ctr.increment
    puts ctr.increment
    puts Counter.count_value

    x_comp = 1
    x_comp += 2
    x_comp ||= 3
    x_comp &&= 4
    puts x_comp

    $my_global = 42
    puts $my_global
  RUBY

  # --- Helper: get old pipeline output at a given level ---

  def old_minify_at_level(code, level, rbs_files: {})
    minify_at_level(code, level, verify_output: false, rbs_files: rbs_files)
  end

  def new_minify_at_level(code, level, rbs_files: {})
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: code,
      file_boundaries: [],
      original_size: code.bytesize,
      stdlib_requires: [],
      rbs_files: rbs_files
    )
    preprocessor = Ryac::Pipeline::Preprocessor.new
    source = preprocessor.call(source)

    result = source.content
    result = Ryac::Pipeline::Compactor.new.call(result)

    stages = Ryac::Minifier::STAGES[level] || Ryac::Minifier::STAGES[5]
    simple, rename = stages.partition { |s| !s.is_a?(Array) }
    simple.each { |klass| result = klass.new.call(result) }

    if rename.any?
      rename_source = Ryac::Pipeline::ConcatenatedSource.new(
        content: result,
        file_boundaries: [],
        original_size: result.bytesize,
        stdlib_requires: [],
        rbs_files: rbs_files
      )
      Ryac::Pipeline::UnifiedRenamer.new.call(rename_source, rename)
    else
      Ryac::Pipeline::RenameResult.new(code: result)
    end
  end

  # Precompute old and new results for each level
  def compressor_results
    @@compressor_results ||= (2..5).to_h do |level|
      [level, {
        old: old_minify_at_level(COMPRESSOR_TEST_CODE, level),
        new: new_minify_at_level(COMPRESSOR_TEST_CODE, level)
      }]
    end
  end

  # === Level 2: Constant aliasing ===

  def test_level2_matches
    assert_equal compressor_results[2][:old], compressor_results[2][:new],
      "Level 2 constant aliasing mismatch"
  end

  # === Level 3: Safe variable renaming ===

  def test_level3_matches
    assert_equal compressor_results[3][:old], compressor_results[3][:new],
      "Level 3 safe variable renaming mismatch"
  end

  # === Level 4: Full variable renaming ===

  def test_level4_matches
    assert_equal compressor_results[4][:old], compressor_results[4][:new],
      "Level 4 full variable renaming mismatch"
  end

  # === Level 5: Method renaming ===

  def test_level5_matches
    assert_equal compressor_results[5][:old], compressor_results[5][:new],
      "Level 5 method renaming mismatch"
  end

  # === Rescue variable produces valid Ruby ===

  def test_rescue_variable_valid_ruby
    result = compressor_results[5][:old]
    assert_equal true, Prism.parse(result.code).errors.empty?,
      "Level 5 rescue variable should produce valid Ruby: #{result.code}"
  end

  # === Hash shorthand preserves key names ===

  def test_hash_shorthand_preserves_key_names
    result = compressor_results[3][:old]
    assert_equal true, result.code.include?("name_arg"),
      "Level 3 hash shorthand should preserve symbol key name: #{result.code}"
  end
end
