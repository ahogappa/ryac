# frozen_string_literal: true

require_relative '../../../test_helper'

class TestConstantRenameMapping < Minitest::Test
  def setup
    @mapping = Ryac::ConstantRenameMapping.new
  end

  def test_initially_empty
    assert @mapping.empty?
    refute @mapping.finalized?
  end

  def test_state_transitions
    @mapping.add_definition_with_path([:MY_CONST], definition_type: :value)
    refute @mapping.empty?
    refute @mapping.finalized?

    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert @mapping.finalized?
  end

  def test_cannot_add_after_finalized
    @mapping.add_definition_with_path([:MY_CONST], definition_type: :value)
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_raises(RuntimeError) { @mapping.add_definition_with_path([:OTHER], definition_type: :value) }
  end

  def test_cannot_increment_after_finalized
    @mapping.add_definition_with_path([:MY_CONST], definition_type: :value)
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_raises(RuntimeError) { @mapping.increment_usage_by_path([:MY_CONST]) }
  end

  def test_value_constant_renamed
    @mapping.add_definition_with_path([:MY_LONG_CONSTANT], definition_type: :value)
    3.times { @mapping.increment_usage_by_path([:MY_LONG_CONSTANT]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_equal "a", @mapping.short_name_for_path([:MY_LONG_CONSTANT])
  end

  def test_class_constant_renamed
    @mapping.add_definition_with_path([:MyClass], definition_type: :class)
    5.times { @mapping.increment_usage_by_path([:MyClass]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_equal 'a', @mapping.short_name_for_path([:MyClass])
  end

  def test_module_constant_renamed
    @mapping.add_definition_with_path([:MyModule], definition_type: :module)
    5.times { @mapping.increment_usage_by_path([:MyModule]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_equal 'a', @mapping.short_name_for_path([:MyModule])
  end

  def test_no_savings_not_renamed
    # Constant "A" (1 char) → candidate "A" same length → no savings
    @mapping.add_definition_with_path([:A], definition_type: :value)
    5.times { @mapping.increment_usage_by_path([:A]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_nil @mapping.short_name_for_path([:A])
  end

  def test_usage_count_tracking
    @mapping.add_definition_with_path([:FOO], definition_type: :value)
    assert_equal 0, @mapping.usage_count_for_path([:FOO])
    @mapping.increment_usage_by_path([:FOO])
    @mapping.increment_usage_by_path([:FOO])
    assert_equal 2, @mapping.usage_count_for_path([:FOO])
  end

  def test_set_usage_count
    @mapping.add_definition_with_path([:FOO], definition_type: :value)
    @mapping.set_usage_count_by_path([:FOO], 10)
    assert_equal 10, @mapping.usage_count_for_path([:FOO])
  end

  def test_exclude_path
    @mapping.add_definition_with_path([:MY_CONST], definition_type: :value)
    @mapping.exclude_path([:MY_CONST])
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_nil @mapping.short_name_for_path([:MY_CONST])
  end

  def test_user_defined_path
    @mapping.add_definition_with_path([:FOO], definition_type: :value)
    assert @mapping.user_defined_path?([:FOO])
    refute @mapping.user_defined_path?([:BAR])
  end

  def test_class_or_module_path
    @mapping.add_definition_with_path([:MyClass], definition_type: :class)
    @mapping.add_definition_with_path([:MY_VAL], definition_type: :value)
    assert @mapping.class_or_module_path?([:MyClass])
    refute @mapping.class_or_module_path?([:MY_VAL])
  end

  def test_short_name_for_by_simple_name
    @mapping.add_definition_with_path([:Foo, :MY_LONG_CONST], definition_type: :value)
    3.times { @mapping.increment_usage_by_path([:Foo, :MY_LONG_CONST]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_equal "a", @mapping.short_name_for(:MY_LONG_CONST)
  end

  def test_nested_constant_path
    @mapping.add_definition_with_path([:Outer, :Inner, :DEEP_CONST], definition_type: :value)
    3.times { @mapping.increment_usage_by_path([:Outer, :Inner, :DEEP_CONST]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_equal "a", @mapping.short_name_for_path([:Outer, :Inner, :DEEP_CONST])
  end

  def test_increment_usage_by_name_increments_all_matches
    @mapping.add_definition_with_path([:Foo, :VAL], definition_type: :value)
    @mapping.add_definition_with_path([:Bar, :VAL], definition_type: :value)
    @mapping.increment_usage(:VAL)
    assert_equal 1, @mapping.usage_count_for_path([:Foo, :VAL])
    assert_equal 1, @mapping.usage_count_for_path([:Bar, :VAL])
  end

  def test_generate_alias_declarations_for_value_constant
    @mapping.add_definition_with_path([:MY_CONST], definition_type: :value)
    3.times { @mapping.increment_usage_by_path([:MY_CONST]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    aliases = @mapping.generate_alias_declarations
    assert_equal ["MY_CONST=a"], aliases
  end

  def test_sorted_by_savings
    @mapping.add_definition_with_path([:SMALL], definition_type: :value)
    2.times { @mapping.increment_usage_by_path([:SMALL]) }
    @mapping.add_definition_with_path([:VERY_LONG_CONSTANT_NAME], definition_type: :value)
    5.times { @mapping.increment_usage_by_path([:VERY_LONG_CONSTANT_NAME]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    # Higher savings gets 'A'
    assert_equal "a", @mapping.short_name_for_path([:VERY_LONG_CONSTANT_NAME])
  end

  def test_each_user_defined_path
    @mapping.add_definition_with_path([:A_CONST], definition_type: :value)
    @mapping.add_definition_with_path([:B_CONST], definition_type: :value)
    paths = []
    @mapping.each_user_defined_path { |p| paths << p }
    assert_equal [[:A_CONST], [:B_CONST]].to_set, paths.to_set
  end

  def test_runtime_class_not_renamed
    # Classes that already exist in the runtime (Array, String, etc.) should not be renamed
    # because renaming would overwrite built-in constants
    @mapping.add_definition_with_path([:Array], definition_type: :class)
    5.times { @mapping.increment_usage_by_path([:Array]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_nil @mapping.short_name_for_path([:Array])
  end

  def test_runtime_module_not_renamed
    @mapping.add_definition_with_path([:Comparable], definition_type: :module)
    5.times { @mapping.increment_usage_by_path([:Comparable]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_nil @mapping.short_name_for_path([:Comparable])
  end

  def test_runtime_nested_class_not_renamed
    # Nested classes that exist in the runtime should also be skipped
    @mapping.add_definition_with_path([:Process, :Status], definition_type: :class)
    5.times { @mapping.increment_usage_by_path([:Process, :Status]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_nil @mapping.short_name_for_path([:Process, :Status])
  end

  def test_nonruntime_class_renamed
    # Classes that don't exist in the runtime SHOULD be renamed
    @mapping.add_definition_with_path([:MyCustomClass], definition_type: :class)
    5.times { @mapping.increment_usage_by_path([:MyCustomClass]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_equal 'a', @mapping.short_name_for_path([:MyCustomClass])
  end

  def test_collision_avoidance_with_existing_names
    # existing_names includes "a" (from constant named :a) → candidate "a" skipped
    @mapping.add_definition_with_path([:a], definition_type: :value)
    @mapping.add_definition_with_path([:MY_LONG_CONST], definition_type: :value)
    3.times { @mapping.increment_usage_by_path([:MY_LONG_CONST]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    short = @mapping.short_name_for_path([:MY_LONG_CONST])
    refute_equal "a", short
    assert_equal "b", short
  end

  def test_skip_class_modules_skips_class
    @mapping.add_definition_with_path([:MyCustomClass], definition_type: :class)
    5.times { @mapping.increment_usage_by_path([:MyCustomClass]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new, skip_class_modules: true)
    assert_nil @mapping.short_name_for_path([:MyCustomClass])
  end

  def test_skip_class_modules_skips_module
    @mapping.add_definition_with_path([:MyModule], definition_type: :module)
    5.times { @mapping.increment_usage_by_path([:MyModule]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new, skip_class_modules: true)
    assert_nil @mapping.short_name_for_path([:MyModule])
  end

  def test_skip_class_modules_still_renames_values
    @mapping.add_definition_with_path([:MyClass], definition_type: :class)
    @mapping.add_definition_with_path([:MY_CONST], definition_type: :value)
    5.times { @mapping.increment_usage_by_path([:MyClass]) }
    3.times { @mapping.increment_usage_by_path([:MY_CONST]) }
    @mapping.assign_short_names(Ryac::NameGenerator.new, skip_class_modules: true)
    assert_nil @mapping.short_name_for_path([:MyClass])
    assert_equal "a", @mapping.short_name_for_path([:MY_CONST])
  end

  # === External prefix support ===

  def test_add_external_prefix
    @mapping.add_external_prefix([:TypeProf, :Core, :AST], usage_count: 20)
    # External prefixes should NOT be user-defined
    refute @mapping.user_defined_path?([:TypeProf, :Core, :AST])
  end

  def test_short_name_for_prefix_after_assign
    @mapping.add_external_prefix([:TypeProf, :Core, :AST], usage_count: 20)
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    short = @mapping.short_name_for_prefix([:TypeProf, :Core, :AST, :CallNode])
    assert_equal "a", short
  end

  def test_short_name_for_prefix_nil_and_short_paths
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_nil @mapping.short_name_for_prefix(nil)
    assert_nil @mapping.short_name_for_prefix([:Foo])
    assert_nil @mapping.short_name_for_prefix([:Foo, :Bar])
  end

  def test_generate_prefix_declarations
    @mapping.add_external_prefix([:TypeProf, :Core, :AST], usage_count: 20)
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    decls = @mapping.generate_prefix_declarations
    assert_equal ["a=TypeProf::Core::AST"], decls
  end

  def test_chained_prefix_declarations
    @mapping.add_external_prefix([:TypeProf, :Core], usage_count: 20)
    @mapping.add_external_prefix([:TypeProf, :Core, :AST], usage_count: 20)
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    decls = @mapping.generate_prefix_declarations
    assert_equal ["b=TypeProf::Core", "a=b::AST"], decls
  end

  def test_external_prefix_below_threshold_not_aliased
    @mapping.add_external_prefix([:A, :B], usage_count: 2)
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    assert_nil @mapping.short_name_for_prefix([:A, :B, :C])
  end

  def test_unified_allocation_internal_and_external
    # Internal constant and external prefix share the same NameGenerator
    @mapping.add_definition_with_path([:VERY_LONG_CONSTANT_NAME], definition_type: :value)
    5.times { @mapping.increment_usage_by_path([:VERY_LONG_CONSTANT_NAME]) }
    @mapping.add_external_prefix([:TypeProf, :Core, :AST], usage_count: 20)
    @mapping.assign_short_names(Ryac::NameGenerator.new)

    # Both should get short names from the same generator (no collision)
    internal_short = @mapping.short_name_for_path([:VERY_LONG_CONSTANT_NAME])
    external_short = @mapping.short_name_for_prefix([:TypeProf, :Core, :AST, :X])
    assert internal_short
    assert external_short
    refute_equal internal_short, external_short
  end

  def test_has_user_defined_prefix
    @mapping.add_definition_with_path([:Foo, :Bar, :Baz], definition_type: :value)
    assert @mapping.has_user_defined_prefix?([:Foo, :Bar, :Baz, :Qux])
    refute @mapping.has_user_defined_prefix?([:Foo, :Bar])
    refute @mapping.has_user_defined_prefix?([:Other])
  end

  def test_preamble_induced_parent_prefix
    # Two sibling external prefixes + some code refs to parent
    @mapping.add_external_prefix([:TypeProf, :Core, :AST], usage_count: 20)
    @mapping.add_external_prefix([:TypeProf, :Core, :Type], usage_count: 20)
    @mapping.add_external_prefix([:TypeProf, :Core], usage_count: 3)
    @mapping.assign_short_names(Ryac::NameGenerator.new)
    decls = @mapping.generate_prefix_declarations

    parent_decl = decls.find { |d| d.include?("TypeProf::Core") && !d.include?("::AST") && !d.include?("::Type") }
    assert parent_decl, "Should alias TypeProf::Core as parent prefix"
    assert decls.any? { |d| d.match?(/=\w+::AST$/) }, "AST should chain through parent"
    assert decls.any? { |d| d.match?(/=\w+::Type$/) }, "Type should chain through parent"
  end
end
