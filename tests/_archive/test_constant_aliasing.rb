# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'test_fixtures'

class TestConstantAliasing < Minitest::Test
  include MinifyTestHelper
  include RenameTestFixtures

  # ===========================================
  # Unit Tests (no minify_code)
  # ===========================================

  def test_constant_name_generator_sequence
    generator = Ryac::NameGenerator.new([], upcase: true)

    assert_equal 'A', generator.next_name
    assert_equal 'B', generator.next_name

    23.times { generator.next_name }
    assert_equal 'Z', generator.next_name

    assert_equal 'A0', generator.next_name
    assert_equal 'A1', generator.next_name

    7.times { generator.next_name }
    assert_equal 'A9', generator.next_name

    assert_equal 'B0', generator.next_name
  end

  def test_name_generator_sequence_with_digits
    generator = Ryac::NameGenerator.new

    ('a'..'z').each { |c| assert_equal c, generator.next_name }

    (0..9).each { |d| assert_equal "a#{d}", generator.next_name }

    (0..9).each { |d| assert_equal "b#{d}", generator.next_name }

    230.times { generator.next_name }
    (0..9).each { |d| assert_equal "z#{d}", generator.next_name }

    assert_equal 'a0a', generator.next_name
    assert_equal 'a0b', generator.next_name

    23.times { generator.next_name }
    assert_equal 'a0z', generator.next_name

    assert_equal 'a1a', generator.next_name
  end

  def test_constant_alias_mapping_basic
    mapping = Ryac::ConstantAliasMapping.new

    mapping.add_definition_with_path([:MyClass], definition_type: :class)
    mapping.add_definition_with_path([:AnotherClass], definition_type: :class)

    5.times { mapping.increment_usage(:MyClass) }
    3.times { mapping.increment_usage(:AnotherClass) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    mapping.freeze_mapping(generator)

    assert_nil mapping.short_name_for(:MyClass)
    assert_nil mapping.short_name_for(:AnotherClass)
  end

  def test_constant_alias_mapping_renames_short_names
    mapping = Ryac::ConstantAliasMapping.new

    mapping.add_definition_with_path([:Foo], definition_type: :class)
    mapping.increment_usage(:Foo)

    mapping.add_definition_with_path([:LongClassName], definition_type: :class)
    3.times { mapping.increment_usage(:LongClassName) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    mapping.freeze_mapping(generator)

    assert_nil mapping.short_name_for(:LongClassName)
    assert_nil mapping.short_name_for(:Foo)
  end

  def test_external_prefix_aliaser_unit
    user_defined_paths = Set.new([[:MyClass]])
    aliaser = Ryac::ExternalPrefixAliaser.new(user_defined_paths)

    10.times { aliaser.collect_reference([:TypeProf, :Core, :AST, :CallNode]) }
    5.times { aliaser.collect_reference([:TypeProf, :Core, :AST, :DefNode]) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    assert aliaser.prefix_aliased?([:TypeProf, :Core, :AST, :CallNode]),
      "Prefix should be aliased when usage provides net savings"

    short_name = aliaser.short_name_for_prefix([:TypeProf, :Core, :AST, :CallNode])
    assert_equal 'A', short_name

    decls = aliaser.generate_prefix_declarations
    assert_equal 1, decls.size
    assert_equal 'A=TypeProf::Core::AST', decls.first
  end

  def test_external_prefix_aliaser_min_savings_threshold
    user_defined_paths = Set.new([[:MyClass]])
    aliaser = Ryac::ExternalPrefixAliaser.new(user_defined_paths)

    aliaser.collect_reference([:Foo, :Bar])

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    refute aliaser.prefix_aliased?([:Foo, :Bar, :Baz]),
      "Short prefix with few uses should not be aliased"
  end

  def test_external_prefix_aliaser_user_defined_excluded
    user_defined_paths = Set.new([[:MyModule, :MyClass]])
    aliaser = Ryac::ExternalPrefixAliaser.new(user_defined_paths)

    10.times { aliaser.collect_reference([:MyModule, :MyClass]) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    decls = aliaser.generate_prefix_declarations
    assert_empty decls, "User-defined paths should not generate prefix declarations"
  end

  def test_external_prefix_aliaser_declaration_references
    user_defined_paths = Set.new
    aliaser = Ryac::ExternalPrefixAliaser.new(user_defined_paths)

    5.times { aliaser.collect_reference([:Lib, :Sub, :ClassA]) }
    3.times { aliaser.collect_reference([:Library, :Config]) }
    3.times { aliaser.collect_reference([:Library, :Loader]) }
    5.times { aliaser.collect_reference([:Library, :Sub, :NodeA]) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    assert aliaser.prefix_aliased?([:Lib, :Sub, :ClassA])
    assert aliaser.prefix_aliased?([:Library, :Sub, :NodeA])
  end

  def test_external_prefix_aliaser_declaration_reference_tips_balance
    user_defined_paths = Set.new
    aliaser = Ryac::ExternalPrefixAliaser.new(user_defined_paths)

    4.times { aliaser.collect_reference([:RuboCop, :Cop, :Team]) }
    4.times { aliaser.collect_reference([:RuboCop, :Cop, :Corrector]) }

    aliaser.collect_reference([:RuboCop, :ProcessedSource])
    aliaser.collect_reference([:RuboCop, :ConfigLoader])
    aliaser.collect_reference([:RuboCop, :Config])

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    assert aliaser.prefix_aliased?([:RuboCop, :Cop, :Team]),
           "RuboCop::Cop should be aliased"

    assert aliaser.prefix_aliased?([:RuboCop, :ProcessedSource]),
           "RuboCop should be aliased (3 direct + 1 declaration ref = 4, net savings = 14)"

    decls = aliaser.generate_prefix_declarations
    rubocop_decl = decls.find { |d| d.include?('RuboCop') && !d.include?('::') }
    assert rubocop_decl, "Should have a declaration for RuboCop alias"

    cop_decl = decls.find { |d| d.include?('Cop') }
    refute cop_decl.include?('RuboCop::Cop'),
           "Cop declaration should use RuboCop alias, not full path: #{cop_decl}"
  end

  def test_external_prefix_aliaser_chained_declarations
    aliaser = Ryac::ExternalPrefixAliaser.new(Set.new)

    10.times { aliaser.collect_reference([:Alpha, :Beta, :Gamma, :ClassX]) }
    10.times { aliaser.collect_reference([:Alpha, :Beta, :Delta, :ClassY]) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    decls = aliaser.generate_prefix_declarations
    parent_idx = decls.index { |d| d.end_with?('Alpha::Beta') }
    assert parent_idx, "Alpha::Beta should be aliased"
    parent_alias = decls[parent_idx].split('=').first

    child_decls = decls.select { |d| d.include?('Gamma') || d.include?('Delta') }
    child_decls.each do |d|
      assert d.include?(parent_alias + '::'),
             "Child declaration should chain through parent alias: #{d}"
    end
  end

  def test_external_prefix_aliaser_common_sub_prefix
    aliaser = Ryac::ExternalPrefixAliaser.new(Set.new)

    10.times { aliaser.collect_reference([:LongPrefix, :SubModule, :GroupA, :NodeX]) }
    10.times { aliaser.collect_reference([:LongPrefix, :SubModule, :GroupB, :NodeY]) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    assert aliaser.prefix_aliased?([:LongPrefix, :SubModule, :GroupA, :NodeX])
    assert aliaser.prefix_aliased?([:LongPrefix, :SubModule, :GroupB, :NodeY])

    decls = aliaser.generate_prefix_declarations
    has_sub_prefix = decls.any? { |d| d.include?('LongPrefix::SubModule') }
    assert has_sub_prefix, "Common sub-prefix LongPrefix::SubModule should be aliased"
  end

  def test_external_prefix_aliaser_single_element_path_ignored
    aliaser = Ryac::ExternalPrefixAliaser.new(Set.new)

    10.times { aliaser.collect_reference([:Foo]) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    assert_equal({}, aliaser.mappings)
    assert_empty aliaser.generate_prefix_declarations
  end

  def test_external_prefix_aliaser_empty_references
    aliaser = Ryac::ExternalPrefixAliaser.new(Set.new)

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    assert_equal({}, aliaser.mappings)
    assert_empty aliaser.generate_prefix_declarations
  end

  def test_external_prefix_aliaser_candidate_length_recalc
    aliaser = Ryac::ExternalPrefixAliaser.new(Set.new)

    3.times { aliaser.collect_reference([:Ab, :X]) }

    existing = ('A'..'Z').to_a
    generator = Ryac::NameGenerator.new(existing, upcase: true)
    aliaser.freeze_mapping(generator)

    refute aliaser.prefix_aliased?([:Ab, :X]),
           "Short prefix should not be aliased when candidate is longer than 1 char"
  end

  def test_external_prefix_aliaser_double_freeze_raises
    aliaser = Ryac::ExternalPrefixAliaser.new(Set.new)
    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    assert_raises(RuntimeError) { aliaser.freeze_mapping(generator) }
  end

  def test_external_prefix_aliaser_declaration_order
    aliaser = Ryac::ExternalPrefixAliaser.new(Set.new)

    10.times { aliaser.collect_reference([:Root, :Mid, :Leaf, :Node]) }
    5.times { aliaser.collect_reference([:Root, :Other]) }

    generator = Ryac::NameGenerator.new([], upcase: true)
    aliaser.freeze_mapping(generator)

    decls = aliaser.generate_prefix_declarations
    depths = decls.map { |d| d.split('=').last.count(':') / 2 + 1 }
    assert_equal depths, depths.sort, "Declarations should be ordered by depth (parents first)"
  end

  # ===========================================
  # Integration tests using shared fixture
  # ===========================================

  def test_constant_aliasing_in_shared_fixture
    result = rename_result_at(2)
    assert_equal false, result.code.include?("MAX_RETRIES"),
      "Value constant MAX_RETRIES should be renamed at level 2"
  end

  def test_module_scoped_constants_in_shared_fixture
    result = rename_result_at(5)
    assert_equal true, result.code.include?("ConstModule"),
      "Module name should be preserved at level 5"
  end

  # ===========================================
  # Group 1: Basic class renaming + Multi-class + Short names/collision
  # ===========================================

  def setup_group_classes
    @group_classes ||= minify_code(<<~RUBY)
      class MyClass; def foo; 1; end; end; MyClass.new.foo
      class UserClass
        def initialize; end
      end
      UserClass.new
      UserClass.new

      class FirstClass; end
      class SecondClass; end
      class ThirdClass; end
      FirstClass.new; FirstClass.new
      SecondClass.new; SecondClass.new
      ThirdClass.new; ThirdClass.new

      class RarelyUsed; end
      class FrequentlyUsed; end
      FrequentlyUsed.new
      FrequentlyUsed.new
      FrequentlyUsed.new
      RarelyUsed.new

      class ConstFoo; end
      class ConstBar; end
      class LongClassName; end
      ConstFoo.new
      ConstBar.new
      LongClassName.new

      class A; end
      class LongClassName1; end
      class LongClassName2; end
      A.new
      LongClassName1.new
      LongClassName2.new
    RUBY
  end

  def test_basic_class_renaming_and_multi_class_and_collision
    result = setup_group_classes
    assert_equal 'class MyClass;def a =1;end;MyClass.new.a;class UserClass;def initialize;end;end;UserClass.new;UserClass.new;class FirstClass;end;class SecondClass;end;class ThirdClass;end;FirstClass.new;FirstClass.new;SecondClass.new;SecondClass.new;ThirdClass.new;ThirdClass.new;class RarelyUsed;end;class FrequentlyUsed;end;FrequentlyUsed.new;FrequentlyUsed.new;FrequentlyUsed.new;RarelyUsed.new;class ConstFoo;end;class ConstBar;end;class LongClassName;end;ConstFoo.new;ConstBar.new;LongClassName.new;class A;end;class LongClassName1;end;class LongClassName2;end;A.new;LongClassName1.new;LongClassName2.new', result.code
    assert_equal '', result.aliases
  end

  # ===========================================
  # Group 2: Value constants + Private constant
  # ===========================================

  def setup_group_value_const
    @group_value_const ||= minify_code(<<~RUBY)
      MAX_RETRIES = 5
      puts MAX_RETRIES

      module FooMod
        module BarMod
          FooMod::BarMod::SOME_VALUE = 42
        end
      end

      module TopMod
        module MidMod
          module DeepMod
            TopMod::MidMod::DeepMod::DEEP_VAL = 99
          end
        end
      end
      puts TopMod::MidMod::DeepMod::DEEP_VAL

      class PrivConstClass
        SOME_CONST = 42
        private_constant :SOME_CONST

        def value
          SOME_CONST
        end
      end
      puts PrivConstClass.new.value
    RUBY
  end

  def test_value_constants_and_private_constant
    result = setup_group_value_const
    assert_equal 'A=5;puts A;module FooMod;module BarMod;FooMod::BarMod::C=42;end;end;module TopMod;module MidMod;module DeepMod;TopMod::MidMod::DeepMod::B=99;end;end;end;puts TopMod::MidMod::DeepMod::B;class PrivConstClass;SOME_CONST=42;private_constant :SOME_CONST;def a =SOME_CONST;end;puts PrivConstClass.new.a', result.code
    assert_equal 'MAX_RETRIES=A;FooMod::BarMod::SOME_VALUE=FooMod::BarMod::C;TopMod::MidMod::DeepMod::DEEP_VAL=TopMod::MidMod::DeepMod::B', result.aliases
  end

  # ===========================================
  # Group 3: Stdlib/external + TypeProf constant resolution
  # ===========================================

  def setup_group_stdlib_and_resolve
    @group_stdlib_and_resolve ||= minify_code(<<~RUBY)
      class StdlibMyClass; end
      arr = Array.new(5)
      hash = Hash.new(0)
      str = String.new("x")
      StdlibMyClass.new

      class Base; end
      Base.new
      Base.new
      Base.new
      File::SEPARATOR

      class ParentClass; end
      class ChildClass < ParentClass; end
      ParentClass.new
      ChildClass.new

      class StrTest; end
      name = "StrTest"
      puts name

      module TpFoo
        module TpBar
          class LongClassName
            def greet
              "hello"
            end
          end
        end
      end

      module TpFoo
        module TpBar
          LongClassName.new.greet
          LongClassName.new.greet
          LongClassName.new.greet
          LongClassName.new.greet
          LongClassName.new.greet
        end
      end

      class MyWorker
        LONG_CONSTANT_NAME = 42

        def value
          LONG_CONSTANT_NAME + LONG_CONSTANT_NAME + LONG_CONSTANT_NAME
        end
      end

      puts MyWorker.new.value
    RUBY
  end

  def test_stdlib_external_and_typeprof_resolve
    result = setup_group_stdlib_and_resolve
    assert_equal 'class StdlibMyClass;end;arr=Array.new(5);hash=Hash.new(0);str=String.new(?x);StdlibMyClass.new;class Base;end;Base.new;Base.new;Base.new;File::SEPARATOR;class ParentClass;end;class ChildClass<ParentClass;end;ParentClass.new;ChildClass.new;class StrTest;end;name="StrTest";puts name;module TpFoo;module TpBar;class LongClassName;def a ="hello";end;end;end;module TpFoo;module TpBar;TpFoo::TpBar::LongClassName.new.a;TpFoo::TpBar::LongClassName.new.a;TpFoo::TpBar::LongClassName.new.a;TpFoo::TpBar::LongClassName.new.a;TpFoo::TpBar::LongClassName.new.a;end;end;class MyWorker;A=42;def a =MyWorker::A+MyWorker::A+MyWorker::A;end;puts MyWorker.new.a', result.code
    assert_equal 'MyWorker::LONG_CONSTANT_NAME=MyWorker::A', result.aliases
  end

  # ===========================================
  # Group 4: Module scoped constants
  # ===========================================

  def setup_group_module_scoped
    @group_module_scoped ||= minify_code(<<~RUBY)
      module MyModule
        class InnerClass
          def value; 42; end
        end
      end
      obj = MyModule::InnerClass.new
      puts obj.value

      module OuterModule
        module MiddleModule
          class DeepClass
            def value; 123; end
          end
        end
      end
      obj2 = OuterModule::MiddleModule::DeepClass.new
      puts obj2.value

      class OuterClass
        class InnerScopeClass
          def value; 42; end
        end
      end
      OuterClass::InnerScopeClass.new
      OuterClass::InnerScopeClass.new

      module Container
        class MyService
          def call; "called"; end
        end
      end
      svc = Container::MyService.new
      puts svc.call

      module ReopenedMod
        SHARED_VAL = 100
      end
      module ReopenedMod
        class Reader
          def read; SHARED_VAL; end
        end
      end
      puts ReopenedMod::Reader.new.read
    RUBY
  end

  def test_module_scoped_constants
    result = setup_group_module_scoped
    assert_equal 'module MyModule;class InnerClass;def a =42;end;end;obj=MyModule::InnerClass.new;puts obj.a;module OuterModule;module MiddleModule;class DeepClass;def a =123;end;end;end;obj2=OuterModule::MiddleModule::DeepClass.new;puts obj2.a;class OuterClass;class InnerScopeClass;def value =42;end;end;OuterClass::InnerScopeClass.new;OuterClass::InnerScopeClass.new;module Container;class MyService;def call ="called";end;end;svc=Container::MyService.new;puts svc.call;module ReopenedMod;A=100;end;module ReopenedMod;class Reader;def a =ReopenedMod::A;end;end;puts ReopenedMod::Reader.new.a', result.code
    assert_equal 'ReopenedMod::SHARED_VAL=ReopenedMod::A', result.aliases
  end

  # ===========================================
  # Group 5: Same name different modules + Case/when
  # ===========================================

  def setup_group_same_name_and_case
    @group_same_name_and_case ||= minify_code(<<~RUBY)
      module SameNameModA
        class InnerClass
          def value; 42; end
        end
      end

      module SameNameModB
        class InnerClass
          def other; 99; end
        end
      end

      obj1 = SameNameModA::InnerClass.new
      obj2 = SameNameModB::InnerClass.new
      puts obj1.value
      puts obj2.other

      module CaseModule
        class LongClassName
          def name; "long"; end
        end

        class AnotherLongName
          def name; "another"; end
        end

        class Runner
          def process(type)
            case type
            when :long
              LongClassName.new.name
            when :another
              AnotherLongName.new.name
            else
              LongClassName.new.name + AnotherLongName.new.name
            end
          end
        end
      end

      puts CaseModule::Runner.new.process(:long)

      module CaseModule2
        class InnerClass2
          def value; 42; end
        end
      end
      CaseModule2::InnerClass2.new
      CaseModule2::InnerClass2.new
      CaseModule2::InnerClass2.new
    RUBY
  end

  def test_same_name_and_case_when
    result = setup_group_same_name_and_case
    assert_equal 'module SameNameModA;class InnerClass;def a =42;end;end;module SameNameModB;class InnerClass;def a =99;end;end;obj1=SameNameModA::InnerClass.new;obj2=SameNameModB::InnerClass.new;puts obj1.a;puts obj2.a;module CaseModule;class LongClassName;def a ="long";end;class AnotherLongName;def a ="another";end;class Runner;def a(a);case a;when :long;CaseModule::LongClassName.new.a;when :another;CaseModule::AnotherLongName.new.a;else;CaseModule::LongClassName.new.a+CaseModule::AnotherLongName.new.a;end;end;end;end;puts CaseModule::Runner.new.a(:long);module CaseModule2;class InnerClass2;def value =42;end;end;CaseModule2::InnerClass2.new;CaseModule2::InnerClass2.new;CaseModule2::InnerClass2.new', result.code
    assert_equal '', result.aliases
  end

  # ===========================================
  # Group 6: Backward-compatible alias declarations
  # ===========================================

  def setup_group_backward_compat
    @group_backward_compat ||= minify_code(<<~RUBY)
      class MyService
        def call; "result"; end
      end
      MyService.new.call
      MyService.new.call

      module BackCompatModule
        class InnerService
          def call; 42; end
        end
      end
      BackCompatModule::InnerService.new.call
      BackCompatModule::InnerService.new.call

      class ShortConstFoo; end
    RUBY
  end

  def test_backward_compat_alias_declarations
    result = setup_group_backward_compat
    assert_equal 'class MyService;def call ="result";end;MyService.new.call;MyService.new.call;module BackCompatModule;class InnerService;def call =42;end;end;BackCompatModule::InnerService.new.call;BackCompatModule::InnerService.new.call;class ShortConstFoo;end', result.code
    assert_equal '', result.aliases
  end

  # ===========================================
  # Individual tests (not groupable)
  # ===========================================

  def test_constant_aliasing_26plus_classes
    class_defs = (1..28).map { |i| "class LongClassName#{i}; end" }.join("\n")
    class_refs = (1..28).map { |i| "LongClassName#{i}.new\nLongClassName#{i}.new" }.join("\n")
    code = class_defs + "\n" + class_refs

    result = minify_code(code)

    assert_equal 'class LongClassName1;end;class LongClassName2;end;class LongClassName3;end;class LongClassName4;end;class LongClassName5;end;class LongClassName6;end;class LongClassName7;end;class LongClassName8;end;class LongClassName9;end;class LongClassName10;end;class LongClassName11;end;class LongClassName12;end;class LongClassName13;end;class LongClassName14;end;class LongClassName15;end;class LongClassName16;end;class LongClassName17;end;class LongClassName18;end;class LongClassName19;end;class LongClassName20;end;class LongClassName21;end;class LongClassName22;end;class LongClassName23;end;class LongClassName24;end;class LongClassName25;end;class LongClassName26;end;class LongClassName27;end;class LongClassName28;end;LongClassName1.new;LongClassName1.new;LongClassName2.new;LongClassName2.new;LongClassName3.new;LongClassName3.new;LongClassName4.new;LongClassName4.new;LongClassName5.new;LongClassName5.new;LongClassName6.new;LongClassName6.new;LongClassName7.new;LongClassName7.new;LongClassName8.new;LongClassName8.new;LongClassName9.new;LongClassName9.new;LongClassName10.new;LongClassName10.new;LongClassName11.new;LongClassName11.new;LongClassName12.new;LongClassName12.new;LongClassName13.new;LongClassName13.new;LongClassName14.new;LongClassName14.new;LongClassName15.new;LongClassName15.new;LongClassName16.new;LongClassName16.new;LongClassName17.new;LongClassName17.new;LongClassName18.new;LongClassName18.new;LongClassName19.new;LongClassName19.new;LongClassName20.new;LongClassName20.new;LongClassName21.new;LongClassName21.new;LongClassName22.new;LongClassName22.new;LongClassName23.new;LongClassName23.new;LongClassName24.new;LongClassName24.new;LongClassName25.new;LongClassName25.new;LongClassName26.new;LongClassName26.new;LongClassName27.new;LongClassName27.new;LongClassName28.new;LongClassName28.new', result.code
    assert_equal '', result.aliases
  end

  def test_external_prefix_aliaser_integration
    code = <<~RUBY
      class MyMinifier
        def process(node)
          case node
          when TypeProf::Core::AST::CallNode
            handle_call
          when TypeProf::Core::AST::DefNode
            handle_def
          when TypeProf::Core::AST::ClassNode
            handle_class
          when TypeProf::Core::AST::ModuleNode
            handle_module
          when TypeProf::Core::AST::IfNode
            handle_if
          when TypeProf::Core::AST::WhileNode
            handle_while
          end
        end

        def handle_call; end
        def handle_def; end
        def handle_class; end
        def handle_module; end
        def handle_if; end
        def handle_while; end
      end
    RUBY

    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: code, file_boundaries: [], original_size: code.bytesize,
      stdlib_requires: [], rbs_files: {}
    )
    source = Ryac::Pipeline::Preprocessor.new.call(source)
    compacted = Ryac::Pipeline::Compactor.new.call(source.content)
    optimized = Ryac::Minifier::OPTIMIZE[0...-1].reduce(compacted) { |r, k| k.new.call(r) }
    optimized = Ryac::Pipeline::ParenOptimizer.new.call(optimized)
    rename_source = Ryac::Pipeline::ConcatenatedSource.new(
      content: optimized, file_boundaries: [], original_size: optimized.bytesize,
      stdlib_requires: [], rbs_files: {}
    )
    stage_defs = [
      [Ryac::Pipeline::ConstantAliaser],
      [Ryac::Pipeline::VariableRenamer],
      [Ryac::Pipeline::MethodRenamer]
    ]
    minified = Ryac::Pipeline::UnifiedRenamer.new.call(rename_source, stage_defs)

    assert_equal 'A=TypeProf::Core::AST;class MyMinifier;def process(a);case a;when A::CallNode;e;when A::DefNode;f;when A::ClassNode;c;when A::ModuleNode;b;when A::IfNode;g;when A::WhileNode;d;end;end;def e;end;def f;end;def c;end;def b;end;def g;end;def d;end;end', minified.code
    assert_equal '', minified.aliases
  end

  # ===========================================
  # Class#name preservation
  # ===========================================

  def test_class_name_preserved_in_output
    code = <<~RUBY
      class MyLongClass
        def greet; "hello"; end
      end
      puts MyLongClass.name
      puts MyLongClass.new.greet
      puts MyLongClass.new.greet
    RUBY
    minify_at_level(code, 2)
  end

  def test_module_name_preserved_in_output
    code = <<~RUBY
      module MyLongModule
        def self.greet; "hi"; end
      end
      puts MyLongModule.name
      puts MyLongModule.greet
      puts MyLongModule.greet
    RUBY
    minify_at_level(code, 2)
  end
end
