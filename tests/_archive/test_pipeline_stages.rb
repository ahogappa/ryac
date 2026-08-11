# frozen_string_literal: true

require_relative 'test_helper'

class TestPipelineStages < Minitest::Test
  include MinifyTestHelper

  # === Shared test code ===

  STAGE_TEST_CODE = <<~RUBY
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

  # Precompute expected results for all levels at once
  def stage_expected
    @@stage_expected ||= (0..5).to_h { |l| [l, minify_at_level(STAGE_TEST_CODE, l)] }
  end

  # === Compactor (Level 0) ===

  def setup_compactor
    @compactor_result ||= begin
      code = "# This is a comment\nx = true\ny = false\nputs(x, y)\n\ndef my_method(my_arg)\n  if my_arg\n    \"hello\"\n  else\n    \"world\"\n  end\nend\nputs my_method(\"a\")\n"
      source = Ryac::Pipeline::ConcatenatedSource.new(
        content: code,
        file_boundaries: [],
        original_size: code.bytesize,
        stdlib_requires: []
      )
      preprocessed = Ryac::Pipeline::Preprocessor.new.call(source)
      { code: code, result: Ryac::Pipeline::Compactor.new.call(preprocessed.content) }
    end
  end

  def test_compactor_matches_level0
    setup_compactor
    expected = minify_at_level(@compactor_result[:code], 0)
    assert_equal expected.code, @compactor_result[:result]
  end

  def test_compactor_preserves_parens
    code = "x = 1\ny = 2\nputs x\nputs(y)\n"
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: code, file_boundaries: [], original_size: code.bytesize, stdlib_requires: []
    )
    preprocessed = Ryac::Pipeline::Preprocessor.new.call(source)
    result = Ryac::Pipeline::Compactor.new.call(preprocessed.content)
    expected = minify_at_level(code, 0)
    assert_equal expected.code, result
  end

  # === OPTIMIZE stages + ParenOptimizer (Level 1) ===

  def setup_level1_combined
    @level1_combined ||= begin
      code = "x = true\ny = false\nputs(x, y)\n\ndef my_method(my_arg)\n  if my_arg\n    \"hello\"\n  else\n    \"world\"\n  end\nend\nputs my_method(\"a\")\n"
      source = Ryac::Pipeline::ConcatenatedSource.new(
        content: code, file_boundaries: [], original_size: code.bytesize, stdlib_requires: []
      )
      preprocessed = Ryac::Pipeline::Preprocessor.new.call(source)
      compacted = Ryac::Pipeline::Compactor.new.call(preprocessed.content)
      optimized = Ryac::Minifier::OPTIMIZE.reduce(compacted) { |r, k| k.new.call(r) }
      { code: code, result: optimized }
    end
  end

  def test_optimize_without_parens_is_subset_of_level1
    setup_level1_combined
    code = @level1_combined[:code]
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: code, file_boundaries: [], original_size: code.bytesize, stdlib_requires: []
    )
    preprocessed = Ryac::Pipeline::Preprocessor.new.call(source)
    compacted = Ryac::Pipeline::Compactor.new.call(preprocessed.content)
    without_parens = Ryac::Minifier::OPTIMIZE[0...-1].reduce(compacted) { |r, k| k.new.call(r) }
    level1 = minify_at_level(code, 1)
    assert_operator without_parens.length, :>=, level1.code.length
  end

  def test_level1_combined_matches
    setup_level1_combined
    expected = minify_at_level(@level1_combined[:code], 1)
    assert_equal expected.code, @level1_combined[:result]
  end

  # === Compactor edge cases ===

  def test_compactor_bare_splat_forwarding
    code = <<~RUBY
      def foo(*args)
        args.sum
      end
      def bar(*)
        foo(*)
      end
      puts bar(1, 2, 3)
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal "def foo(*args);args.sum;end;def bar(*);foo(*);end;puts(bar(1,2,3))", result
  end

  def test_compactor_case_without_predicate
    code = <<~RUBY
      x = 42
      result = case
      when x > 100
        "big"
      when x > 10
        "medium"
      else
        "small"
      end
      puts result
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal "x=42;result=case;when x>100;\"big\";when x>10;\"medium\";else;\"small\";end;puts(result)", result
  end

  def test_compactor_or_with_return
    code = <<~RUBY
      def foo
        x = bar or return false
        x + 1
      end
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal "def foo;x=bar or return false;x+1;end", result
  end

  def test_compactor_and_with_return
    code = <<~RUBY
      def foo
        x = bar and return true
        x + 1
      end
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal "def foo;x=bar and return true;x+1;end", result
  end

  def test_compactor_multi_statement_parens_in_while
    code = <<~RUBY
      arr = [6, 15, 35]
      arr.each do |value|
        while (q, r = value.divmod(2); r) == 0
          value = q
        end
        puts value
      end
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal "arr=[6,15,35];arr.each{|value|while (q,r=value.divmod(2);r)==0;value=q;end;puts(value)}", result
  end

  def test_compactor_shareable_constant
    code = <<~RUBY
      # shareable_constant_value: literal
      FOO = [1, 2, 3].freeze
      puts FOO.inspect
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal "FOO=[1,2,3].freeze;puts(FOO.inspect)", result
  end

  def test_compactor_string_with_double_quote
    code = <<~'RUBY'
      puts '"'
      puts "hello"
      puts '\''
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal "puts(\"\\\"\")" + ';puts("hello");' + "puts(\"'\")", result
  end

  def test_compactor_match_operator_after_constant
    code = <<~RUBY
      RE = /foo/
      def check(s)
        (RE =~ s) == 0
      end
      puts check("foobar")
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'RE=/foo/;def check(s);RE=~s==0;end;puts(check("foobar"))', result
  end

  def test_compactor_keyword_arg_symbol_default
    code = <<~RUBY
      def step(x, any_type: :element, order: :forward)
        [x, any_type, order]
      end
      puts step(1).inspect
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'def step(x,any_type: :element,order: :forward);[x,any_type,order];end;puts(step(1).inspect)', result
  end

  def test_compactor_heredoc_single_quoted
    code = <<~'RUBY'
      X = <<'XXX'
      hello
      world
      XXX
      puts X
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'X="hello\nworld\n";puts(X)', result
  end

  def test_compactor_heredoc_double_quoted
    code = <<~'RUBY'
      X = <<~HEREDOC
        hello
        world
      HEREDOC
      puts X
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'X="hello\nworld\n";puts(X)', result
  end

  def test_compactor_heredoc_interpolated
    code = <<~'RUBY'
      name = "Alice"
      x = <<~HEREDOC
        hello #{name}
        world
      HEREDOC
      puts x
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'name="Alice";x="hello #{name}\nworld\n";puts(x)', result
  end

  def test_compactor_return_if_expression
    code = <<~RUBY
      def foo(x)
        return x ? 1 : 0
      end
      puts foo(true)
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'def foo(x);return(if x;1;else;0;end);end;puts(foo(true))', result
  end

  def test_compactor_return_unless_expression
    code = <<~RUBY
      def bar(x)
        return unless x
        42
      end
      puts bar(true)
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'def bar(x);unless x;return;end;42;end;puts(bar(true))', result
  end

  def test_compactor_regexp_with_quote_delimiter
    code = '%r"hello"i'
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal '/hello/i', result
  end

  def test_compactor_regexp_with_angle_delimiter
    code = '%r<foo/bar>m'
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal '/foo\/bar/m', result
  end

  def test_compactor_block_with_splat_param
    code = <<~RUBY
      arr = [[1,2],[3,4]]
      arr.each {|*v| puts v.inspect }
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'arr=[[1,2],[3,4]];arr.each{|*v|puts(v.inspect)}', result
  end

  def test_compactor_block_with_optional_and_rest
    code = <<~RUBY
      def test
        foo {|a, b=1, *c, &d| puts a, c.inspect }
      end
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'def test;foo{|a,b=1,*c,&d|puts(a,c.inspect)};end', result
  end

  def test_compactor_parens_assignment_as_receiver
    code = <<~RUBY
      q = "HELLO_WORLD"
      (q = q.downcase).tr!('_', '-')
      puts q
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'q="HELLO_WORLD";(q=q.downcase).tr!("_","-");puts(q)', result
  end

  def test_compactor_and_or_precedence
    code = <<~RUBY
      def foo(opt, rest)
        opt and (!rest or opt == "x")
      end
      puts foo("y", true)
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'def foo(opt,rest);opt and (!rest or opt=="x");end;puts(foo("y",true))', result
  end

  def test_compactor_or_and_precedence
    code = <<~RUBY
      def bar(a, b, c)
        a or (b and c)
      end
      puts bar(nil, true, false)
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'def bar(a,b,c);a or (b and c);end;puts(bar(nil,true,false))', result
  end

  def test_compactor_pipe_xor_precedence
    code = <<~RUBY
      a = 1
      b = 2
      c = 3
      puts a | (b ^ c)
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'a=1;b=2;c=3;puts(a|(b^c))', result
  end

  def test_compactor_not_match_operator_spacing
    code = "pattern=\"hello\"\nx=pattern !~ /xyz/\ny=@a !~ /abc/\n変数=\"world\"\nz=変数 !~ /xyz/\n"
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'pattern="hello";x=pattern !~/xyz/;y=@a!~/abc/;変数="world";z=変数 !~/xyz/', result
  end

  def test_compactor_heredoc_with_special_chars
    code = <<~'RUBY'
      X = <<~'HEREDOC'
        line with "quotes"
        and a	tab
      HEREDOC
      puts X
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'X="line with \"quotes\"\nand a\ttab\n";puts(X)', result
  end

  def test_compactor_predicate_method_before_equals
    code = <<~RUBY
      x = [1.0/0].first
      puts x.infinite? == 1
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'x=[1.0/0].first;puts(x.infinite? ==1)', result
  end

  def test_compactor_regexp_with_slash
    code = '%r[foo/bar]'
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal '/foo\/bar/', result
  end

  def test_compactor_call_target_node
    code = <<~RUBY
      obj = Struct.new(:x, :y).new(1, 2)
      obj2 = Struct.new(:a).new(10)
      obj.x, obj2.a = obj2.a, obj.x
      puts obj.x
      puts obj2.a
    RUBY
    result = Ryac::Pipeline::Compactor.new.call(code)
    assert_equal 'obj=Struct.new(:x,:y).new(1,2);obj2=Struct.new(:a).new(10);obj.x,obj2.a=obj2.a,obj.x;puts(obj.x);puts(obj2.a)', result
  end

end
