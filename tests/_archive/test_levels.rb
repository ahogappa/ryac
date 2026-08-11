# frozen_string_literal: true

require_relative '../test_helper'

class TestLevels < Minitest::Test
  include MinifyTestHelper

  # Comprehensive Ruby program exercising features visible at each minification level.
  #
  # Reserved words covered: module, class, def, end, if, elsif, else, unless,
  #   case, when, while, until, for, in, do, begin, rescue, ensure, retry,
  #   return, break, next, yield, super, self, true, false, nil, and, or, not,
  #   defined?, alias, then, raise, attr_reader, attr_accessor
  # Also: heredoc, regex, splat, double splat, &block, lambda, safe navigation,
  #   %w[], %i[], multiple assignment, string interpolation, rescue modifier,
  #   range, block_given?
  LEVEL_TEST_CODE = <<~'RUBY'
    # Comprehensive Ruby feature test — covers all practical reserved words
    module MathUtils
      MULTIPLIER = 2 + 3

      def self.double_value(number)
        number * MULTIPLIER
      end

      def self.clamp_value(value, min_val, max_val)
        if value < min_val then
          min_val
        elsif value > max_val
          max_val
        else
          value
        end
      end
    end

    class Base
      def parent_info
        "base"
      end
    end

    class Calculator < Base
      OFFSET = 1 << 8
      LABELS = %w[low medium high].freeze
      SYMBOLS = %i[add subtract multiply].freeze

      attr_reader :current_value
      attr_accessor :label

      def initialize(initial_value, label: "default")
        @current_value = initial_value
        @label = label
        @history = []
        @@instance_count ||= 0
        @@instance_count += 1
        $last_calculator = self
      end

      def add_number(amount, verbose: false)
        @current_value = @current_value + amount
        @history.push(amount)
        if verbose
          "added"
        else
          "silent"
        end
      end

      def subtract_number(amount)
        @current_value - amount
      end

      alias neg subtract_number

      def multiply_by_offset
        @current_value * Calculator::OFFSET
      end

      def reset_value
        @current_value = 0
        counter = 0
        counter += 1 while counter < 3
        $last_calculator = nil
        counter
      end

      def get_separator
        "x"
      end

      def describe_value
        if @current_value > 100
          "big"
        else
          "small"
        end
      end

      def check_positive
        unless @current_value > 0
          "non-positive"
        end
      end

      def process_items(items)
        items.each do |item|
          puts item
        end
      end

      def safe_divide(divisor)
        begin
          @current_value / divisor
        rescue ZeroDivisionError
          0
        ensure
          @history.push(:divide)
        end
      end

      def classify_value
        case @current_value
        when 0..10
          "low"
        when 11..100
          "medium"
        else
          "high"
        end
      end

      def value_with_label
        "#{@label}: #{@current_value}"
      end

      def to_s
        "Calculator(#{@current_value})"
      end

      def parent_info
        super
      end

      def with_yield
        yield @current_value if block_given?
      end

      def count_up(limit)
        result = []
        idx = 0
        until idx >= limit
          idx += 1
          next if idx == 2
          break if idx > 4
          result.push(idx)
        end
        result
      end

      def retry_example
        attempts = 0
        begin
          attempts += 1
          raise "fail" if attempts < 2
          attempts
        rescue
          retry if attempts < 2
          0
        end
      end

      def check_defined
        defined?(@current_value) ? "yes" : "no"
      end

      def logic_test(flag_a, flag_b)
        if flag_a and not flag_b
          "a only"
        elsif flag_a or flag_b
          "at least one"
        else
          "none"
        end
      end

      def safe_access(obj)
        obj&.to_s
      end

      def return_early(value)
        return "negative" if value < 0
        return "zero" if value == 0
        "positive"
      end

      def multi_assign
        first, *rest = [1, 2, 3, 4]
        first + rest.length
      end

      def splat_args(*args, **kwargs)
        args.length + kwargs.length
      end

      def with_block(&block)
        block ? block.call(@current_value) : nil
      end

      def use_lambda
        fn = ->(val) { val * 2 }
        fn.call(@current_value)
      end

      def heredoc_example
        text = <<~HEREDOC
          hello
          world
        HEREDOC
        text.strip
      end

      def regex_example(input)
        input =~ /^calc/i ? true : false
      end

      def for_loop
        total = 0
        for num in [10, 20, 30]
          total += num
        end
        total
      end

      def rescue_modifier_example
        Integer("abc") rescue 0
      end
    end

    class Formatter
      def format_number(value, prefix: "", suffix: "")
        result = "#{prefix}#{value}#{suffix}"
        result
      end

      def format_flag(flag)
        if flag == true
          "yes"
        else
          "no"
        end
      end
    end

    # Main execution
    calc = Calculator.new(10, label: "main")
    calc.add_number(5, verbose: true)
    calc.add_number(3, verbose: false)
    puts calc.subtract_number(2)
    puts calc.neg(1)
    puts calc.multiply_by_offset
    puts calc.reset_value
    puts Calculator::OFFSET
    puts calc.get_separator
    puts calc.describe_value
    puts calc.check_positive
    puts calc.safe_divide(0)
    puts calc.classify_value
    puts calc.value_with_label
    puts calc.to_s
    puts calc.parent_info
    calc.with_yield { |v| puts v }
    puts calc.count_up(5).inspect
    puts calc.retry_example
    puts calc.check_defined
    puts calc.logic_test(true, false)
    puts calc.logic_test(false, true)
    puts calc.logic_test(false, false)
    puts calc.safe_access("hello")
    puts calc.safe_access(nil)
    puts calc.return_early(-1)
    puts calc.return_early(0)
    puts calc.return_early(1)
    puts calc.multi_assign
    puts calc.splat_args(1, 2, 3, a: 4)
    puts calc.with_block { |v| v + 100 }
    puts calc.use_lambda
    puts calc.heredoc_example
    puts calc.regex_example("calculator")
    puts calc.regex_example("other")
    puts calc.for_loop
    puts calc.rescue_modifier_example
    puts MathUtils::MULTIPLIER
    puts MathUtils.double_value(7)
    puts MathUtils.clamp_value(150, 0, 100)

    fmt = Formatter.new
    puts fmt.format_number(42, prefix: "$", suffix: "!")
    puts fmt.format_flag(true)
    puts fmt.format_flag(false)

    doubled = MathUtils.double_value(Calculator::OFFSET)
    puts doubled

    puts Calculator::LABELS.inspect
    puts Calculator::SYMBOLS.inspect
  RUBY

  # L0: Compactor only — comments/whitespace removed, semicolons inserted
  def test_level_0
    result = minify_at_level(LEVEL_TEST_CODE, 0)
    expected = [
      'module MathUtils;',
      'MULTIPLIER=2+3;',
      'def self.double_value(number);number*MULTIPLIER;end;',
      'def self.clamp_value(value,min_val,max_val);',
      'if value<min_val;min_val;elsif value>max_val;max_val;else;value;end;end;',
      'end;',
      'class Base;def parent_info;"base";end;end;',
      'class Calculator<Base;',
      'OFFSET=1<<8;',
      'LABELS=%w[low medium high].freeze;',
      'SYMBOLS=%i[add subtract multiply].freeze;',
      'attr_reader(:current_value);',
      'attr_accessor(:label);',
      'def initialize(initial_value,label:"default");',
      '@current_value=initial_value;',
      '@label=label;',
      '@history=[];',
      '@@instance_count||=0;',
      '@@instance_count+=1;',
      '$last_calculator=self;',
      'end;',
      'def add_number(amount,verbose:false);',
      '@current_value=@current_value+amount;',
      '@history.push(amount);',
      'if verbose;"added";else;"silent";end;',
      'end;',
      'def subtract_number(amount);@current_value-amount;end;',
      'alias neg subtract_number;',
      'def multiply_by_offset;@current_value*Calculator::OFFSET;end;',
      'def reset_value;',
      '@current_value=0;',
      'counter=0;',
      'while counter<3;counter+=1;end;',
      '$last_calculator=nil;',
      'counter;',
      'end;',
      'def get_separator;"x";end;',
      'def describe_value;if @current_value>100;"big";else;"small";end;end;',
      'def check_positive;unless @current_value>0;"non-positive";end;end;',
      'def process_items(items);items.each{|item|puts(item)};end;',
      'def safe_divide(divisor);begin;@current_value/divisor;',
      'rescue ZeroDivisionError;0;ensure;@history.push(:divide);end;end;',
      'def classify_value;case @current_value;',
      'when (0..10);"low";',
      'when (11..100);"medium";',
      'else;"high";end;end;',
      'def value_with_label;"#{@label}: #{@current_value}";end;',
      'def to_s;"Calculator(#{@current_value})";end;',
      'def parent_info;super;end;',
      'def with_yield;if block_given?;yield(@current_value);end;end;',
      'def count_up(limit);result=[];idx=0;',
      'until idx>=limit;idx+=1;',
      'if idx==2;next;end;',
      'if idx>4;break;end;',
      'result.push(idx);end;result;end;',
      'def retry_example;attempts=0;begin;attempts+=1;',
      'if attempts<2;raise("fail");end;attempts;',
      'rescue;if attempts<2;retry;end;0;end;end;',
      'def check_defined;if defined?(@current_value);"yes";else;"no";end;end;',
      'def logic_test(flag_a,flag_b);',
      'if flag_a and !flag_b;"a only";',
      'elsif flag_a or flag_b;"at least one";',
      'else;"none";end;end;',
      'def safe_access(obj);obj&.to_s;end;',
      'def return_early(value);if value<0;return "negative";end;',
      'if value==0;return "zero";end;"positive";end;',
      'def multi_assign;first,*rest=1,2,3,4;first+rest.length;end;',
      'def splat_args(*args,**kwargs);args.length+kwargs.length;end;',
      'def with_block(&block);if block;block.call(@current_value);end;end;',
      'def use_lambda;fn=->(val){val*2};fn.call(@current_value);end;',
      'def heredoc_example;text="hello\nworld\n";text.strip;end;',
      'def regex_example(input);if input=~/^calc/i;true;else;false;end;end;',
      'def for_loop;total=0;for num in [10,20,30];total+=num;end;total;end;',
      'def rescue_modifier_example;(Integer("abc") rescue 0);end;',
      'end;',
      'class Formatter;',
      'def format_number(value,prefix:"",suffix:"");"#{prefix}#{value}#{suffix}";end;',
      'def format_flag(flag);if flag==true;"yes";else;"no";end;end;',
      'end;',
      'calc=Calculator.new(10,label:"main");',
      'calc.add_number(5,verbose:true);',
      'calc.add_number(3,verbose:false);',
      'puts(calc.subtract_number(2));',
      'puts(calc.neg(1));',
      'puts(calc.multiply_by_offset);',
      'puts(calc.reset_value);',
      'puts(Calculator::OFFSET);',
      'puts(calc.get_separator);',
      'puts(calc.describe_value);',
      'puts(calc.check_positive);',
      'puts(calc.safe_divide(0));',
      'puts(calc.classify_value);',
      'puts(calc.value_with_label);',
      'puts(calc.to_s);',
      'puts(calc.parent_info);',
      'calc.with_yield{|v|puts(v)};',
      'puts(calc.count_up(5).inspect);',
      'puts(calc.retry_example);',
      'puts(calc.check_defined);',
      'puts(calc.logic_test(true,false));',
      'puts(calc.logic_test(false,true));',
      'puts(calc.logic_test(false,false));',
      'puts(calc.safe_access("hello"));',
      'puts(calc.safe_access(nil));',
      'puts(calc.return_early(-1));',
      'puts(calc.return_early(0));',
      'puts(calc.return_early(1));',
      'puts(calc.multi_assign);',
      'puts(calc.splat_args(1,2,3,a:4));',
      'puts(calc.with_block{|v|v+100});',
      'puts(calc.use_lambda);',
      'puts(calc.heredoc_example);',
      'puts(calc.regex_example("calculator"));',
      'puts(calc.regex_example("other"));',
      'puts(calc.for_loop);',
      'puts(calc.rescue_modifier_example);',
      'puts(MathUtils::MULTIPLIER);',
      'puts(MathUtils.double_value(7));',
      'puts(MathUtils.clamp_value(150,0,100));',
      'fmt=Formatter.new;',
      'puts(fmt.format_number(42,prefix:"$",suffix:"!"));',
      'puts(fmt.format_flag(true));',
      'puts(fmt.format_flag(false));',
      'doubled=MathUtils.double_value(Calculator::OFFSET);',
      'puts(doubled);',
      'puts(Calculator::LABELS.inspect);',
      'puts(Calculator::SYMBOLS.inspect)',
    ].join('')
    assert_equal expected, result.code
  end

  # L1: Syntax optimizations — boolean shorten, char shorten, constant fold,
  #     control flow simplify, endless method, paren optimizer
  def test_level_1
    result = minify_at_level(LEVEL_TEST_CODE, 1)
    expected = [
      'module MathUtils;',
      'MULTIPLIER=5;',                                                    # 2+3 folded
      'def self.double_value(number) =number*MULTIPLIER;',               # endless
      'def self.clamp_value(value,min_val,max_val) =',
      'value<min_val ? min_val : value>max_val ? max_val : value;',      # elsif→nested ternary
      'end;',
      'class Base;def parent_info ="base";end;',                         # endless
      'class Calculator<Base;',
      'OFFSET=256;',                                                     # 1<<8 folded
      'LABELS=%w[low medium high].freeze;',
      'SYMBOLS=%i[add subtract multiply].freeze;',
      'attr_reader :current_value;',                                     # paren removed
      'attr_accessor :label;',
      'def initialize(initial_value,label:"default");',
      '@current_value=initial_value;',
      '@label=label;',
      '@history=[];',
      '@@instance_count||=0;',
      '@@instance_count+=1;',
      '$last_calculator=self;',
      'end;',
      'def add_number(amount,verbose:!1);',                              # false→!1
      '@current_value=@current_value+amount;',
      '@history.push amount;',
      'verbose ? "added":"silent";',                                     # if/else→ternary
      'end;',
      'def subtract_number(amount) =@current_value-amount;',            # endless
      'alias neg subtract_number;',
      'def multiply_by_offset =@current_value*Calculator::OFFSET;',     # endless
      'def reset_value;',
      '@current_value=0;',
      'counter=0;',
      'counter+=1 while counter<3;',                                     # while→modifier
      '$last_calculator=nil;',
      'counter;',
      'end;',
      'def get_separator =?x;',                                          # endless + "x"→?x
      'def describe_value =@current_value>100?"big":"small";',           # endless + ternary
      'def check_positive;',
      '"non-positive" unless @current_value>0;',                         # unless→modifier
      'end;',
      'def process_items(items) =items.each{|item|puts item};',          # endless + paren removed
      'def safe_divide(divisor);begin;@current_value/divisor;',
      'rescue ZeroDivisionError;0;ensure;@history.push :divide;end;end;',
      'def classify_value;case @current_value;',
      'when (0..10);"low";',
      'when (11..100);"medium";',
      'else;"high";end;end;',
      'def value_with_label ="#{@label}: #{@current_value}";',           # endless
      'def to_s ="Calculator(#{@current_value})";',                      # endless
      'def parent_info =super;',                                         # endless
      'def with_yield;yield @current_value if block_given?;end;',
      'def count_up(limit);result=[];idx=0;',
      'until idx>=limit;idx+=1;',
      'next if idx==2;',                                                 # if→modifier
      'break if idx>4;',
      'result.push idx;end;result;end;',
      'def retry_example;attempts=0;begin;attempts+=1;',
      'raise "fail" if attempts<2;',                                     # if→modifier + paren removed
      'attempts;rescue;retry if attempts<2;0;end;end;',
      'def check_defined =defined?(@current_value)?"yes":"no";',         # endless + ternary
      'def logic_test(flag_a,flag_b) =',
      '(flag_a and !flag_b) ? "a only":',                                # and/or wrapped in parens
      '(flag_a or flag_b) ? "at least one":"none";',
      'def safe_access(obj) =obj&.to_s;',                                # endless
      'def return_early(value);',
      'return "negative" if value<0;',
      'return "zero" if value==0;',
      '"positive";end;',
      'def multi_assign;first,*rest=1,2,3,4;first+rest.length;end;',
      'def splat_args(*args,**kwargs) =args.length+kwargs.length;',      # endless
      'def with_block(&block);block.call @current_value if block;end;',
      'def use_lambda;fn=->(val){val*2};fn.call @current_value;end;',
      'def heredoc_example;text="hello\nworld\n";text.strip;end;',
      'def regex_example(input) =input=~/^calc/i?!!1:!1;',              # endless + true→!!1
      'def for_loop;total=0;',
      'for num in [10,20,30];total+=num;end;total;end;',
      'def rescue_modifier_example =(Integer("abc") rescue 0);',         # endless
      'end;',
      'class Formatter;',
      'def format_number(value,prefix:"",suffix:"") ="#{prefix}#{value}#{suffix}";',
      'def format_flag(flag) =flag==!!1 ? "yes":"no";',                  # endless + true→!!1
      'end;',
      'calc=Calculator.new 10,label:"main";',
      'calc.add_number 5,verbose:!!1;',                                  # true→!!1
      'calc.add_number 3,verbose:!1;',                                   # false→!1
      'puts calc.subtract_number(2);',                                   # paren removed
      'puts calc.neg(1);',
      'puts calc.multiply_by_offset;',
      'puts calc.reset_value;',
      'puts Calculator::OFFSET;',
      'puts calc.get_separator;',
      'puts calc.describe_value;',
      'puts calc.check_positive;',
      'puts calc.safe_divide(0);',
      'puts calc.classify_value;',
      'puts calc.value_with_label;',
      'puts calc.to_s;',
      'puts calc.parent_info;',
      'calc.with_yield{|v|puts v};',
      'puts calc.count_up(5).inspect;',
      'puts calc.retry_example;',
      'puts calc.check_defined;',
      'puts calc.logic_test(!!1,!1);',                                   # true→!!1, false→!1
      'puts calc.logic_test(!1,!!1);',
      'puts calc.logic_test(!1,!1);',
      'puts calc.safe_access("hello");',
      'puts calc.safe_access(nil);',
      'puts calc.return_early(-1);',
      'puts calc.return_early(0);',
      'puts calc.return_early(1);',
      'puts calc.multi_assign;',
      'puts calc.splat_args(1,2,3,a:4);',
      'puts(calc.with_block{|v|v+100});',
      'puts calc.use_lambda;',
      'puts calc.heredoc_example;',
      'puts calc.regex_example("calculator");',
      'puts calc.regex_example("other");',
      'puts calc.for_loop;',
      'puts calc.rescue_modifier_example;',
      'puts MathUtils::MULTIPLIER;',
      'puts MathUtils.double_value(7);',
      'puts MathUtils.clamp_value(150,0,100);',
      'fmt=Formatter.new;',
      'puts fmt.format_number(42,prefix:"$",suffix:"!");',
      'puts fmt.format_flag(!!1);',                                      # true→!!1
      'puts fmt.format_flag(!1);',                                       # false→!1
      'doubled=MathUtils.double_value Calculator::OFFSET;',
      'puts doubled;',
      'puts Calculator::LABELS.inspect;',
      'puts Calculator::SYMBOLS.inspect',
    ].join('')
    assert_equal expected, result.code
  end

  # L2: Constant aliasing — MULTIPLIER→A, OFFSET→B, LABELS→D, SYMBOLS→C
  def test_level_2
    result = minify_at_level(LEVEL_TEST_CODE, 2)
    expected = [
      'module MathUtils;',
      'A=5;',                                                            # MULTIPLIER→A
      'def self.double_value(number) =number*MathUtils::A;',
      'def self.clamp_value(value,min_val,max_val) =',
      'value<min_val ? min_val : value>max_val ? max_val : value;',
      'end;',
      'class Base;def parent_info ="base";end;',
      'class Calculator<Base;',
      'B=256;',                                                          # OFFSET→B
      'D=%w[low medium high].freeze;',                                   # LABELS→D
      'C=%i[add subtract multiply].freeze;',                             # SYMBOLS→C
      'attr_reader :current_value;',
      'attr_accessor :label;',
      'def initialize(initial_value,label:"default");',
      '@current_value=initial_value;',
      '@label=label;',
      '@history=[];',
      '@@instance_count||=0;',
      '@@instance_count+=1;',
      '$last_calculator=self;',
      'end;',
      'def add_number(amount,verbose:!1);',
      '@current_value=@current_value+amount;',
      '@history.push amount;',
      'verbose ? "added":"silent";',
      'end;',
      'def subtract_number(amount) =@current_value-amount;',
      'alias neg subtract_number;',
      'def multiply_by_offset =@current_value*Calculator::B;',          # OFFSET→B
      'def reset_value;',
      '@current_value=0;',
      'counter=0;',
      'counter+=1 while counter<3;',
      '$last_calculator=nil;',
      'counter;',
      'end;',
      'def get_separator =?x;',
      'def describe_value =@current_value>100?"big":"small";',
      'def check_positive;',
      '"non-positive" unless @current_value>0;',
      'end;',
      'def process_items(items) =items.each{|item|puts item};',
      'def safe_divide(divisor);begin;@current_value/divisor;',
      'rescue ZeroDivisionError;0;ensure;@history.push :divide;end;end;',
      'def classify_value;case @current_value;',
      'when (0..10);"low";',
      'when (11..100);"medium";',
      'else;"high";end;end;',
      'def value_with_label ="#{@label}: #{@current_value}";',
      'def to_s ="Calculator(#{@current_value})";',
      'def parent_info =super;',
      'def with_yield;yield @current_value if block_given?;end;',
      'def count_up(limit);result=[];idx=0;',
      'until idx>=limit;idx+=1;',
      'next if idx==2;',
      'break if idx>4;',
      'result.push idx;end;result;end;',
      'def retry_example;attempts=0;begin;attempts+=1;',
      'raise "fail" if attempts<2;',
      'attempts;rescue;retry if attempts<2;0;end;end;',
      'def check_defined =defined?(@current_value)?"yes":"no";',
      'def logic_test(flag_a,flag_b) =',
      '(flag_a and !flag_b) ? "a only":',
      '(flag_a or flag_b) ? "at least one":"none";',
      'def safe_access(obj) =obj&.to_s;',
      'def return_early(value);',
      'return "negative" if value<0;',
      'return "zero" if value==0;',
      '"positive";end;',
      'def multi_assign;first,*rest=1,2,3,4;first+rest.length;end;',
      'def splat_args(*args,**kwargs) =args.length+kwargs.length;',
      'def with_block(&block);block.call @current_value if block;end;',
      'def use_lambda;fn=->(val){val*2};fn.call @current_value;end;',
      'def heredoc_example;text="hello\nworld\n";text.strip;end;',
      'def regex_example(input) =input=~/^calc/i?!!1:!1;',
      'def for_loop;total=0;',
      'for num in [10,20,30];total+=num;end;total;end;',
      'def rescue_modifier_example =(Integer("abc") rescue 0);',
      'end;',
      'class Formatter;',
      'def format_number(value,prefix:"",suffix:"") ="#{prefix}#{value}#{suffix}";',
      'def format_flag(flag) =flag==!!1 ? "yes":"no";',
      'end;',
      'calc=Calculator.new 10,label:"main";',
      'calc.add_number 5,verbose:!!1;',
      'calc.add_number 3,verbose:!1;',
      'puts calc.subtract_number(2);',
      'puts calc.neg(1);',
      'puts calc.multiply_by_offset;',
      'puts calc.reset_value;',
      'puts Calculator::B;',                                            # OFFSET→B
      'puts calc.get_separator;',
      'puts calc.describe_value;',
      'puts calc.check_positive;',
      'puts calc.safe_divide(0);',
      'puts calc.classify_value;',
      'puts calc.value_with_label;',
      'puts calc.to_s;',
      'puts calc.parent_info;',
      'calc.with_yield{|v|puts v};',
      'puts calc.count_up(5).inspect;',
      'puts calc.retry_example;',
      'puts calc.check_defined;',
      'puts calc.logic_test(!!1,!1);',
      'puts calc.logic_test(!1,!!1);',
      'puts calc.logic_test(!1,!1);',
      'puts calc.safe_access("hello");',
      'puts calc.safe_access(nil);',
      'puts calc.return_early(-1);',
      'puts calc.return_early(0);',
      'puts calc.return_early(1);',
      'puts calc.multi_assign;',
      'puts calc.splat_args(1,2,3,a:4);',
      'puts(calc.with_block{|v|v+100});',
      'puts calc.use_lambda;',
      'puts calc.heredoc_example;',
      'puts calc.regex_example("calculator");',
      'puts calc.regex_example("other");',
      'puts calc.for_loop;',
      'puts calc.rescue_modifier_example;',
      'puts MathUtils::A;',                                             # MULTIPLIER→A
      'puts MathUtils.double_value(7);',
      'puts MathUtils.clamp_value(150,0,100);',
      'fmt=Formatter.new;',
      'puts fmt.format_number(42,prefix:"$",suffix:"!");',
      'puts fmt.format_flag(!!1);',
      'puts fmt.format_flag(!1);',
      'doubled=MathUtils.double_value Calculator::B;',                   # OFFSET→B
      'puts doubled;',
      'puts Calculator::D.inspect;',                                     # LABELS→D
      'puts Calculator::C.inspect',                                      # SYMBOLS→C
    ].join('')
    assert_equal expected, result.code
    assert_equal [
      'Calculator::LABELS=Calculator::D;',
      'Calculator::OFFSET=Calculator::B;',
      'Calculator::SYMBOLS=Calculator::C;',
      'MathUtils::MULTIPLIER=MathUtils::A',
    ].join(''), result.aliases
  end

  # L3: Variable renaming (locals + keywords)
  def test_level_3
    result = minify_at_level(LEVEL_TEST_CODE, 3)
    expected = [
      'module MathUtils;',
      'A=5;',
      'def self.double_value(a) =a*MathUtils::A;',                      # number→a
      'def self.clamp_value(a,b,c) =a<b ? b : a>c ? c : a;',           # value→a, min_val→b, max_val→c
      'end;',
      'class Base;def parent_info ="base";end;',
      'class Calculator<Base;',
      'B=256;',
      'D=%w[low medium high].freeze;',
      'C=%i[add subtract multiply].freeze;',
      'attr_reader :current_value;',
      'attr_accessor :label;',
      'def initialize(b,a:"default");',                                  # initial_value→b, label:→a:
      '@current_value=b;',
      '@label=a;',
      '@history=[];',
      '@@instance_count||=0;',
      '@@instance_count+=1;',
      '$last_calculator=self;',
      'end;',
      'def add_number(b,a:!1);',                                         # amount→b, verbose:→a:
      '@current_value=@current_value+b;',
      '@history.push b;',
      'a ? "added":"silent";',
      'end;',
      'def subtract_number(a) =@current_value-a;',                      # amount→a
      'alias neg subtract_number;',
      'def multiply_by_offset =@current_value*Calculator::B;',
      'def reset_value;',
      '@current_value=0;',
      'a=0;',                                                            # counter→a
      'a+=1 while a<3;',
      '$last_calculator=nil;',
      'a;',
      'end;',
      'def get_separator =?x;',
      'def describe_value =@current_value>100?"big":"small";',
      'def check_positive;',
      '"non-positive" unless @current_value>0;',
      'end;',
      'def process_items(a) =a.each{puts _1};',                          # items→a, block param→_1
      'def safe_divide(a);begin;@current_value/a;',                      # divisor→a
      'rescue ZeroDivisionError;0;ensure;@history.push :divide;end;end;',
      'def classify_value;case @current_value;',
      'when (0..10);"low";',
      'when (11..100);"medium";',
      'else;"high";end;end;',
      'def value_with_label ="#{@label}: #{@current_value}";',
      'def to_s ="Calculator(#{@current_value})";',
      'def parent_info =super;',
      'def with_yield;yield @current_value if block_given?;end;',
      'def count_up(a);b=[];c=0;',                                      # limit→a, result→b, idx→c
      'until c>=a;c+=1;',
      'next if c==2;',
      'break if c>4;',
      'b.push c;end;b;end;',
      'def retry_example;a=0;begin;a+=1;',                              # attempts→a
      'raise "fail" if a<2;',
      'a;rescue;retry if a<2;0;end;end;',
      'def check_defined =defined?(@current_value)?"yes":"no";',
      'def logic_test(a,b) =',                                           # flag_a→a, flag_b→b
      '(a and !b) ? "a only":',
      '(a or b) ? "at least one":"none";',
      'def safe_access(a) =a&.to_s;',                                    # obj→a
      'def return_early(a);',                                             # value→a
      'return "negative" if a<0;',
      'return "zero" if a==0;',
      '"positive";end;',
      'def multi_assign;a,*b=1,2,3,4;a+b.length;end;',                  # first→a, rest→b
      'def splat_args(*a,**b) =a.length+b.length;',                     # args→a, kwargs→b
      'def with_block(&a);a.call @current_value if a;end;',             # block→a
      'def use_lambda;a=->(val){val*2};a.call @current_value;end;',     # fn→a
      'def heredoc_example;a="hello\nworld\n";a.strip;end;',            # text→a
      'def regex_example(a) =a=~/^calc/i?!!1:!1;',                      # input→a
      'def for_loop;a=0;',                                               # total→a
      'for b in [10,20,30];a+=b;end;a;end;',                            # num→b
      'def rescue_modifier_example =(Integer("abc") rescue 0);',
      'end;',
      'class Formatter;',
      'def format_number(c,a:"",b:"") ="#{a}#{c}#{b}";',               # value→c, prefix:→a:, suffix:→b:
      'def format_flag(a) =a==!!1 ? "yes":"no";',                       # flag→a
      'end;',
      'calc=Calculator.new 10,a:"main";',                                # label:→a:
      'calc.add_number 5,a:!!1;',                                        # verbose:→a:
      'calc.add_number 3,a:!1;',
      'puts calc.subtract_number(2);',
      'puts calc.neg(1);',
      'puts calc.multiply_by_offset;',
      'puts calc.reset_value;',
      'puts Calculator::B;',
      'puts calc.get_separator;',
      'puts calc.describe_value;',
      'puts calc.check_positive;',
      'puts calc.safe_divide(0);',
      'puts calc.classify_value;',
      'puts calc.value_with_label;',
      'puts calc.to_s;',
      'puts calc.parent_info;',
      'calc.with_yield{puts _1};',                                       # block param→_1
      'puts calc.count_up(5).inspect;',
      'puts calc.retry_example;',
      'puts calc.check_defined;',
      'puts calc.logic_test(!!1,!1);',
      'puts calc.logic_test(!1,!!1);',
      'puts calc.logic_test(!1,!1);',
      'puts calc.safe_access("hello");',
      'puts calc.safe_access(nil);',
      'puts calc.return_early(-1);',
      'puts calc.return_early(0);',
      'puts calc.return_early(1);',
      'puts calc.multi_assign;',
      'puts calc.splat_args(1,2,3,a:4);',                               # a:→a:
      'puts(calc.with_block{_1+100});',                                   # block param→_1
      'puts calc.use_lambda;',
      'puts calc.heredoc_example;',
      'puts calc.regex_example("calculator");',
      'puts calc.regex_example("other");',
      'puts calc.for_loop;',
      'puts calc.rescue_modifier_example;',
      'puts MathUtils::A;',
      'puts MathUtils.double_value(7);',
      'puts MathUtils.clamp_value(150,0,100);',
      'fmt=Formatter.new;',
      'puts fmt.format_number(42,a:"$",b:"!");',                         # prefix:→a:, suffix:→b:
      'puts fmt.format_flag(!!1);',
      'puts fmt.format_flag(!1);',
      'doubled=MathUtils.double_value Calculator::B;',
      'puts doubled;',
      'puts Calculator::D.inspect;',
      'puts Calculator::C.inspect',
    ].join('')
    assert_equal expected, result.code
  end

  # L4: Full variable renaming (locals + keywords + @ivar + @@cvar + $gvar)
  def test_level_4
    result = minify_at_level(LEVEL_TEST_CODE, 4)
    expected = [
      'module MathUtils;',
      'A=5;',
      'def self.double_value(a) =a*MathUtils::A;',
      'def self.clamp_value(a,b,c) =a<b ? b : a>c ? c : a;',
      'end;',
      'class Base;def parent_info ="base";end;',
      'class Calculator<Base;',
      'B=256;',
      'D=%w[low medium high].freeze;',
      'C=%i[add subtract multiply].freeze;',
      'attr_reader :current_value;',
      'attr_accessor :label;',
      'def initialize(b,a:"default");',
      '@current_value=b;',
      '@label=a;',
      '@a=[];',                                                          # @history→@a
      '@@a||=0;',                                                        # @@instance_count→@@a
      '@@a+=1;',
      '$a=self;',                                                        # $last_calculator→$a
      'end;',
      'def add_number(b,a:!1);',
      '@current_value=@current_value+b;',
      '@a.push b;',                                                      # @history→@a
      'a ? "added":"silent";',
      'end;',
      'def subtract_number(a) =@current_value-a;',
      'alias neg subtract_number;',
      'def multiply_by_offset =@current_value*Calculator::B;',
      'def reset_value;',
      '@current_value=0;',
      'a=0;',
      'a+=1 while a<3;',
      '$a=nil;',                                                         # $last_calculator→$a
      'a;',
      'end;',
      'def get_separator =?x;',
      'def describe_value =@current_value>100?"big":"small";',
      'def check_positive;',
      '"non-positive" unless @current_value>0;',
      'end;',
      'def process_items(a) =a.each{puts _1};',
      'def safe_divide(a);begin;@current_value/a;',
      'rescue ZeroDivisionError;0;ensure;@a.push :divide;end;end;',     # @history→@a
      'def classify_value;case @current_value;',
      'when (0..10);"low";',
      'when (11..100);"medium";',
      'else;"high";end;end;',
      'def value_with_label ="#{@label}: #{@current_value}";',
      'def to_s ="Calculator(#{@current_value})";',
      'def parent_info =super;',
      'def with_yield;yield @current_value if block_given?;end;',
      'def count_up(a);b=[];c=0;',
      'until c>=a;c+=1;',
      'next if c==2;',
      'break if c>4;',
      'b.push c;end;b;end;',
      'def retry_example;a=0;begin;a+=1;',
      'raise "fail" if a<2;',
      'a;rescue;retry if a<2;0;end;end;',
      'def check_defined =defined?(@current_value)?"yes":"no";',
      'def logic_test(a,b) =',
      '(a and !b) ? "a only":',
      '(a or b) ? "at least one":"none";',
      'def safe_access(a) =a&.to_s;',
      'def return_early(a);',
      'return "negative" if a<0;',
      'return "zero" if a==0;',
      '"positive";end;',
      'def multi_assign;a,*b=1,2,3,4;a+b.length;end;',
      'def splat_args(*a,**b) =a.length+b.length;',
      'def with_block(&a);a.call @current_value if a;end;',
      'def use_lambda;a=->(val){val*2};a.call @current_value;end;',
      'def heredoc_example;a="hello\nworld\n";a.strip;end;',
      'def regex_example(a) =a=~/^calc/i?!!1:!1;',
      'def for_loop;a=0;',
      'for b in [10,20,30];a+=b;end;a;end;',
      'def rescue_modifier_example =(Integer("abc") rescue 0);',
      'end;',
      'class Formatter;',
      'def format_number(c,a:"",b:"") ="#{a}#{c}#{b}";',
      'def format_flag(a) =a==!!1 ? "yes":"no";',
      'end;',
      'calc=Calculator.new 10,a:"main";',
      'calc.add_number 5,a:!!1;',
      'calc.add_number 3,a:!1;',
      'puts calc.subtract_number(2);',
      'puts calc.neg(1);',
      'puts calc.multiply_by_offset;',
      'puts calc.reset_value;',
      'puts Calculator::B;',
      'puts calc.get_separator;',
      'puts calc.describe_value;',
      'puts calc.check_positive;',
      'puts calc.safe_divide(0);',
      'puts calc.classify_value;',
      'puts calc.value_with_label;',
      'puts calc.to_s;',
      'puts calc.parent_info;',
      'calc.with_yield{puts _1};',
      'puts calc.count_up(5).inspect;',
      'puts calc.retry_example;',
      'puts calc.check_defined;',
      'puts calc.logic_test(!!1,!1);',
      'puts calc.logic_test(!1,!!1);',
      'puts calc.logic_test(!1,!1);',
      'puts calc.safe_access("hello");',
      'puts calc.safe_access(nil);',
      'puts calc.return_early(-1);',
      'puts calc.return_early(0);',
      'puts calc.return_early(1);',
      'puts calc.multi_assign;',
      'puts calc.splat_args(1,2,3,a:4);',
      'puts(calc.with_block{_1+100});',
      'puts calc.use_lambda;',
      'puts calc.heredoc_example;',
      'puts calc.regex_example("calculator");',
      'puts calc.regex_example("other");',
      'puts calc.for_loop;',
      'puts calc.rescue_modifier_example;',
      'puts MathUtils::A;',
      'puts MathUtils.double_value(7);',
      'puts MathUtils.clamp_value(150,0,100);',
      'fmt=Formatter.new;',
      'puts fmt.format_number(42,a:"$",b:"!");',
      'puts fmt.format_flag(!!1);',
      'puts fmt.format_flag(!1);',
      'doubled=MathUtils.double_value Calculator::B;',
      'puts doubled;',
      'puts Calculator::D.inspect;',
      'puts Calculator::C.inspect',
    ].join('')
    assert_equal expected, result.code
  end

  # L5: Full renaming (locals + keywords + ivars + cvars + gvars + methods)
  def test_level_5
    result = minify_at_level(LEVEL_TEST_CODE, 5)
    expected = [
      'module MathUtils;',
      'A=5;',
      'def self.a(a) =a*MathUtils::A;',                                 # double_value→a
      'def self.b(a,b,c) =a<b ? b : a>c ? c : a;',                     # clamp_value→b
      'end;',
      'class Base;def g ="base";end;',                                   # parent_info→g
      'class Calculator<Base;',
      'B=256;',
      'D=%w[low medium high].freeze;',
      'C=%i[add subtract multiply].freeze;',
      'attr :current_value;',                                            # attr_reader→attr
      'attr :label,true;',                                               # attr_accessor→attr :x,true
      'def initialize(b,a:"default");',
      '@current_value=b;',
      '@label=a;',
      '@a=[];',
      '@@a||=0;',
      '@@a+=1;',
      '$a=self;',
      'end;',
      'def i(b,a:!1);',                                                  # add_number→i
      '@current_value=@current_value+b;',
      '@a.push b;',
      'a ? "added":"silent";',
      'end;',
      'def subtract_number(a) =@current_value-a;',
      'alias neg subtract_number;',
      'def e =@current_value*Calculator::B;',                            # multiply_by_offset→e
      'def s;',                                                          # reset_value→s
      '@current_value=0;',
      'a=0;',
      'a+=1 while a<3;',
      '$a=nil;',
      'a;',
      'end;',
      'def q =?x;',                                                      # get_separator→q
      'def m =@current_value>100?"big":"small";',                        # describe_value→m
      'def k;',                                                          # check_positive→k
      '"non-positive" unless @current_value>0;',
      'end;',
      'def process_items(a) =a.each{puts _1};',
      'def t(a);begin;@current_value/a;',                                # safe_divide→t
      'rescue ZeroDivisionError;0;ensure;@a.push :divide;end;end;',
      'def l;case @current_value;',                                      # classify_value→l
      'when (0..10);"low";',
      'when (11..100);"medium";',
      'else;"high";end;end;',
      'def h ="#{@label}: #{@current_value}";',                          # value_with_label→h
      'def to_s ="Calculator(#{@current_value})";',
      'def g =super;',                                                   # parent_info→g
      'def x;yield @current_value if block_given?;end;',                 # with_yield→x
      'def z(a);b=[];c=0;',                                              # count_up→z
      'until c>=a;c+=1;',
      'next if c==2;',
      'break if c>4;',
      'b.push c;end;b;end;',
      'def n;a=0;begin;a+=1;',                                           # retry_example→n
      'raise "fail" if a<2;',
      'a;rescue;retry if a<2;0;end;end;',
      'def o =defined?(@current_value)?"yes":"no";',                     # check_defined→o
      'def c(a,b) =',                                                    # logic_test→c
      '(a and !b) ? "a only":',
      '(a or b) ? "at least one":"none";',
      'def f(a) =a&.to_s;',                                              # safe_access→f
      'def a(a);',                                                       # return_early→a
      'return "negative" if a<0;',
      'return "zero" if a==0;',
      '"positive";end;',
      'def r;a,*b=1,2,3,4;a+b.size;end;',                               # multi_assign→r, length→size
      'def w(*a,**b) =a.size+b.size;',                                   # splat_args→w, length→size
      'def u(&a);a.call @current_value if a;end;',                       # with_block→u
      'def v;a=->(val){val*2};a.call @current_value;end;',               # use_lambda→v
      'def j;a="hello\nworld\n";a.strip;end;',                           # heredoc_example→j
      'def d(a) =a=~/^calc/i?!!1:!1;',                                  # regex_example→d
      'def y;a=0;',                                                      # for_loop→y
      'for b in [10,20,30];a+=b;end;a;end;',
      'def b =(Integer("abc") rescue 0);',                               # rescue_modifier_example→b
      'end;',
      'class Formatter;',
      'def b(c,a:"",b:"") ="#{a}#{c}#{b}";',                            # format_number→b
      'def a(a) =a==!!1 ? "yes":"no";',                                  # format_flag→a
      'end;',
      'calc=Calculator.new 10,a:"main";',
      'calc.i 5,a:!!1;',                                                 # add_number→i
      'calc.i 3,a:!1;',
      'puts calc.subtract_number(2);',
      'puts calc.neg(1);',
      'puts calc.e;',                                                    # multiply_by_offset→e
      'puts calc.s;',                                                    # reset_value→s
      'puts Calculator::B;',
      'puts calc.q;',                                                    # get_separator→q
      'puts calc.m;',                                                    # describe_value→m
      'puts calc.k;',                                                    # check_positive→k
      'puts calc.t(0);',                                                 # safe_divide→t
      'puts calc.l;',                                                    # classify_value→l
      'puts calc.h;',                                                    # value_with_label→h
      'puts calc.to_s;',
      'puts calc.g;',                                                    # parent_info→g
      'calc.x{puts _1};',                                                # with_yield→x
      'puts calc.z(5).inspect;',                                         # count_up→z
      'puts calc.n;',                                                    # retry_example→n
      'puts calc.o;',                                                    # check_defined→o
      'puts calc.c(!!1,!1);',                                            # logic_test→c
      'puts calc.c(!1,!!1);',
      'puts calc.c(!1,!1);',
      'puts calc.f("hello");',                                           # safe_access→f
      'puts calc.f(nil);',
      'puts calc.a(-1);',                                                # return_early→a
      'puts calc.a(0);',
      'puts calc.a(1);',
      'puts calc.r;',                                                    # multi_assign→r
      'puts calc.w(1,2,3,a:4);',                                        # splat_args→w
      'puts(calc.u{_1+100});',                                            # with_block→u
      'puts calc.v;',                                                    # use_lambda→v
      'puts calc.j;',                                                    # heredoc_example→j
      'puts calc.d("calculator");',                                      # regex_example→d
      'puts calc.d("other");',
      'puts calc.y;',                                                    # for_loop→y
      'puts calc.b;',                                                    # rescue_modifier_example→b
      'puts MathUtils::A;',
      'puts MathUtils.a(7);',                                            # double_value→a
      'puts MathUtils.b(150,0,100);',                                    # clamp_value→b
      'fmt=Formatter.new;',
      'puts fmt.b(42,a:"$",b:"!");',                                    # format_number→b
      'puts fmt.a(!!1);',                                                # format_flag→a
      'puts fmt.a(!1);',
      'doubled=MathUtils.a Calculator::B;',                               # double_value→a
      'puts doubled;',
      'puts Calculator::D.inspect;',
      'puts Calculator::C.inspect',
    ].join('')
    assert_equal expected, result.code
  end

  def test_default_level_is_3
    assert_equal 3, Ryac::Minifier::DEFAULT_LEVEL
  end

  # Compression should be monotonically non-increasing across levels
  def test_monotonic_compression
    sizes = (0..5).map { |l| minify_at_level(LEVEL_TEST_CODE, l, verify_output: false).code.bytesize }
    sizes.each_cons(2) do |higher, lower|
      assert_operator higher, :>=, lower,
        "Level compression should be monotonically non-increasing: #{sizes.inspect}"
    end
  end
end
