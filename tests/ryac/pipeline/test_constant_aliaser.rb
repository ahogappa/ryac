# frozen_string_literal: true

require_relative '../../test_helper'
require 'tmpdir'

class TestConstantAliaserPipeline < Minitest::Test
  include MinifyTestHelper

  def test_alias_declarations_generated
    code = <<~RUBY
      module MathUtils
        MULTIPLIER = 5
      end
      class Calculator
        OFFSET = 256
        LABELS = %w[low medium high].freeze
        SYMBOLS = %i[add subtract multiply].freeze
        def test = OFFSET + LABELS.size + SYMBOLS.size
      end
      puts Calculator.new.test
      puts MathUtils::MULTIPLIER
    RUBY
    result = minify_at_level(code, 2)
    assert_equal [
      'Calculator::LABELS=Calculator::D;',
      'Calculator::OFFSET=Calculator::C;',
      'Calculator::SYMBOLS=Calculator::B;',
      'MathUtils::MULTIPLIER=MathUtils::A',
    ].join(''), result.aliases
  end

  def test_external_prefix_aliased
    code = <<~RUBY
      class App
        def run
          puts Process::Status.name
          puts Process::Sys.name
          puts Process::UID.name
          puts Process::GID.name
          puts Process::Tms.name
        end
      end
      App.new.run
    RUBY
    result = minify_at_level(code, 2)
    assert_equal 'A=Process', result.preamble
    assert_equal 'class App;def run =(puts A::Status.name;puts A::Sys.name;puts A::UID.name;puts A::GID.name;puts A::Tms.name);end;App.new.run',
                 result.code
  end

  # Prism has no RBS in the analysis environment, so type analysis cannot
  # resolve Prism::CallNode — but the chain is spelled in full from a
  # constant root that the program's own `require "prism"` provides, which
  # is all an alias declaration needs once the requires are re-emitted ahead
  # of it. Without the fallback every unresolvable gem reference stays at
  # full length. This goes through Minifier because the require hoisting
  # that makes the ordering sound lives in the collector/concatenator.
  def test_external_prefix_aliased_without_type_resolution
    code = <<~RUBY
      require "prism"
      class Scanner
        def run(src)
          root = Prism.parse(src).value
          [Prism::CallNode, Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].count do |klass|
            root.statements.body.first.is_a?(klass)
          end
        end
      end
      puts Scanner.new.run("x = 1")
    RUBY
    Dir.mktmpdir('aliaser') do |dir|
      path = File.join(dir, 'scanner.rb')
      File.write(path, code)
      result = Ryac::Minifier.new.call(path, level: MinifyTestHelper::STAGE_RECIPES[2])
      assert_equal 'require "prism";A=Prism;class Scanner;def run(src) =' \
                   '(root=Prism.parse(src).value;[A::CallNode,A::DefNode,A::ClassNode,A::ModuleNode]' \
                   '.count{|klass|root.statements.body.first.is_a?(klass)});end;' \
                   'puts Scanner.new.run("x = 1")',
                   result.content

      original_out, original_ok = run_ruby_code(code)
      minified_out, minified_ok = run_ruby_code(result.content)
      assert original_ok && minified_ok, "both variants must run"
      assert_equal original_out, minified_out
    end
  end

  # Without a top-level require to anchor the root, the fallback must stay
  # off: an alias in the preamble would raise at boot for a constant the
  # original program only touches when the reference is reached.
  def test_unresolved_external_without_require_not_aliased
    code = <<~RUBY
      class Worker
        def run
          LazyGem::Config.load
          LazyGem::Config.load
          LazyGem::Config.load
          LazyGem::Config.load
        end
      end
    RUBY
    Dir.mktmpdir('aliaser') do |dir|
      path = File.join(dir, 'worker.rb')
      File.write(path, code)
      result = Ryac::Minifier.new.call(path, level: MinifyTestHelper::STAGE_RECIPES[2])
      assert_equal 'class Worker;def run =(LazyGem::Config.load;LazyGem::Config.load;' \
                   'LazyGem::Config.load;LazyGem::Config.load);end',
                   result.content
      assert_equal '', result.preamble
    end
  end

  def test_external_prefix_uses_resolved_path_for_unqualified_refs
    code = <<~RUBY
      module Outer
        module Other
          class Worker
            def run
              Inner::Leaf.new
              Inner::Leaf.new
              Inner::Leaf.new
            end
          end
        end
      end
    RUBY
    rbs_files = { "outer.rbs" => <<~RBS }
      module Outer
        module Inner
          class Leaf
            def initialize: () -> void
          end
        end
      end
    RBS
    result = minify_at_level(code, 2, verify_output: false, rbs_files: rbs_files)
    assert_equal 'A=Outer::Inner', result.preamble
    assert_equal 'module Outer;module Other;class Worker;def run =(A::Leaf.new;A::Leaf.new;A::Leaf.new);end;end;end',
                 result.code
  end

  def test_constant_path_write_and_superclass_renaming
    code = <<~RUBY
      module Framework
        class Base
          TIMEOUT = 30
          def run = TIMEOUT
        end
        class Server < Base
          PORT = 8080
          def start = PORT
        end
      end
      Framework::MAX_CONNECTIONS = 100
      puts Framework::Server.new.start
      puts Framework::Server.new.run
      puts Framework::MAX_CONNECTIONS
    RUBY
    result = minify_at_level(code, 2)
    assert_equal 'module Framework;class Base;B=30;def run =B;end;class Server<Framework::Base;C=8080;def start =C;end;end;Framework::A=100;' \
                 'puts Framework::Server.new.start;puts Framework::Server.new.run;puts Framework::A',
                 result.code
    assert_equal 'Framework::MAX_CONNECTIONS=Framework::A;Framework::Base::TIMEOUT=Framework::Base::B;Framework::Server::PORT=Framework::Server::C',
                 result.aliases
  end

  def test_def_receiver_patching
    code = <<~RUBY
      class Formatter
        SEPARATOR = "-"
        def self.format(str)
          str + SEPARATOR + str
        end
      end
      def Formatter.short(str)
        str[0..2]
      end
      puts Formatter.format("abc")
      puts Formatter.short("hello")
    RUBY
    result = minify_at_level(code, 2)
    assert_equal 'class Formatter;A="-";def self.format(str) =str+A+str;end;' \
                 'def Formatter.short(str) =str[0..2];puts Formatter.format("abc");puts Formatter.short("hello")',
                 result.code
    assert_equal 'Formatter::SEPARATOR=Formatter::A', result.aliases
  end

  def test_aliased_constant_prefix_not_in_preamble
    code = <<~RUBY
      module Outer
        module Inner
          class Leaf
          end
        end
        AliasedInner = Inner
        module Consumer
          class Worker
            def run
              AliasedInner::Leaf.new
              AliasedInner::Leaf.new
              AliasedInner::Leaf.new
            end
          end
        end
      end
    RUBY
    result = minify_at_level(code, 3, verify_output: false)
    assert_equal '', result.preamble
  end

  def test_unresolved_external_constant_inside_module_not_aliased_in_preamble
    code = <<~RUBY
      module RuboCopLike
        module Cop
          class AssignmentCheck
            EQUALS = AST::Node::EQUALS_ASSIGNMENTS
            EQUALS2 = AST::Node::EQUALS_ASSIGNMENTS
            EQUALS3 = AST::Node::EQUALS_ASSIGNMENTS
            def check(node)
              EQUALS.include?(node.type) || EQUALS2.include?(node.type) || EQUALS3.include?(node.type)
            end
          end
        end
      end
    RUBY
    result = minify_at_level(code, 2, verify_output: false)
    assert_equal '', result.preamble
  end

  def test_unresolved_top_level_external_constant_not_aliased_in_preamble
    code = <<~RUBY
      class Worker
        def run
          SomeGem::Config.load
          SomeGem::Config.load
          SomeGem::Config.load
          SomeGem::Config.load
          SomeGem::Config.load
        end
      end
    RUBY
    result = minify_at_level(code, 2, verify_output: false)
    assert_equal '', result.preamble
    assert_equal 'class Worker;def run =(SomeGem::Config.load;SomeGem::Config.load;SomeGem::Config.load;SomeGem::Config.load;SomeGem::Config.load);end',
                 result.code
  end

  def test_aliased_constant_references_are_renamed
    code = <<~RUBY
      module Outer
        module External
          module Macros
            def helper; end
          end
        end
        AliasConst = External
        class Base
          extend AliasConst::Macros
        end
        class Worker < Base
          extend AliasConst::Macros
        end
        class Runner < Base
          extend AliasConst::Macros
        end
      end
    RUBY
    result = minify_at_level(code, 2, verify_output: false)
    assert_equal 'module Outer;module External;module Macros;def helper;end;end;end;' \
                 'A=External;class Base;extend A::Macros;end;' \
                 'class Worker<Outer::Base;extend A::Macros;end;' \
                 'class Runner<Outer::Base;extend A::Macros;end;end',
                 result.code
    assert_equal 'Outer::AliasConst=Outer::A', result.aliases
    assert_equal '', result.preamble
  end

  def test_singleton_class_constant_not_renamed
    # Constants defined in `class << self` live on the metaclass —
    # they cannot be accessed as `Foo::X` from outside, so alias
    # declarations would fail. They must be excluded from renaming.
    code = <<~RUBY
      class Foo
        class << self
          PATTERNS = [/foo/, /bar/]
          def get_patterns
            PATTERNS
          end
        end
        def self.use_patterns
          puts get_patterns.inspect
        end
      end
      Foo.use_patterns
    RUBY
    result = minify_at_level(code, 2)
    assert_equal 'class Foo;class<<self;PATTERNS=[/foo/,/bar/];def get_patterns =PATTERNS;end;def self.use_patterns =puts get_patterns.inspect;end;Foo.use_patterns',
                 result.code
  end

  # Prism models `A, B = ...` as ConstantTargetNodes rather than
  # ConstantWriteNodes. Missing them renamed every reference while leaving the
  # definitions untouched, so the short names were never assigned to anything.
  def test_multi_assigned_constants_renamed_at_definition
    code = "class CPU\n" \
           "  RP2A03_CC = 12\n" \
           "  CLK_1, CLK_2, CLK_3 = (1..3).map { |i| i * RP2A03_CC }\n" \
           "  def tick(n)\n" \
           "    n == 1 ? CLK_1 : n == 2 ? CLK_2 : CLK_3\n" \
           "  end\n" \
           "end\n" \
           "p CPU.new.tick(2)"
    result = minify_at_level(code, 4)
    assert_equal 'class E;A=12;B,C,D=(1..3).map{_1*A};def a(a) =a==1?B : a==2?C : D;end;p E.new.a(2)',
                 result.code
  end
end
