# frozen_string_literal: true

require_relative '../test_helper'

# The pipeline's output contracts. Every bug in this project's history shipped
# as structurally plausible output — code that parsed, or parsed and quietly
# computed something else — so each contract here exists to convert a class of
# silent corruption into a failed run at the stage that caused it.
class TestPostconditions < Minitest::Test
  class Probe
    include Ryac::RenameInvariants
  end

  def test_output_that_does_not_parse_is_rejected
    minifier = Ryac::Minifier.new
    error = assert_raises(Ryac::Pipeline::InvalidOutputError) do
      minifier.send(:verify_parses, 'def f(', 'content')
    end
    assert_equal 'minified content does not parse (1:6: unexpected end-of-input; ' \
                 'expected a `)` to close the parameters; 1:6: unexpected end-of-input, ' \
                 'assuming it is closing the parent top level context; ' \
                 '1:0: expected an `end` to close the `def` statement)',
                 error.message
  end

  def test_duplicated_parameter_names_are_rejected_as_unparseable
    minifier = Ryac::Minifier.new
    assert_raises(Ryac::Pipeline::InvalidOutputError) do
      minifier.send(:verify_parses, 'def f(c, c: {}) = c', 'content')
    end
  end

  def test_empty_output_sections_are_fine
    minifier = Ryac::Minifier.new
    minifier.send(:verify_parses, '', 'aliases')
  end

  def test_analysis_stage_rejects_the_standalone_driver
    error = assert_raises(Ryac::InternalError) do
      Ryac::Pipeline::ConstantAliaser.new.call('x = 1')
    end
    assert_equal 'Ryac::Pipeline::ConstantAliaser needs analysis; run it through StageRunner',
                 error.message
  end

  def test_two_locals_collapsing_into_one_name_is_rejected
    error = assert_raises(Ryac::Pipeline::RenameCollisionError) do
      Probe.new.verify_injective!({ code: 'c', rbs_files: 'c' }, 'def run_stages')
    end
    assert_equal 'rename collision in def run_stages: code, rbs_files -> c', error.message
  end

  def test_distinct_local_names_pass
    Probe.new.verify_injective!({ code: 'a', stages: 'b' }, 'def run_stages')
  end

  def test_two_methods_sharing_a_final_name_in_one_namespace_are_rejected
    mapping = Ryac::MethodRenameMapping.new
    mapping.add_method([[:AstUtils], false, :unwrap_statements].freeze, nil)
    mapping.add_method([[:AstUtils], false, :expressionish?].freeze, nil)
    shorts = mapping.instance_variable_get(:@key_short_names)
    shorts[[[:AstUtils], false, :unwrap_statements]] = 'g'
    shorts[[[:AstUtils], false, :expressionish?]] = 'g'

    error = assert_raises(Ryac::Pipeline::RenameCollisionError) { mapping.verify_no_shadowing! }
    assert_equal 'rename collision in AstUtils#: unwrap_statements, expressionish? -> g',
                 error.message
  end

  def test_renamed_method_landing_on_a_kept_name_is_rejected
    mapping = Ryac::MethodRenameMapping.new
    mapping.add_method([[:M], false, :a].freeze, nil)
    mapping.add_method([[:M], false, :long_name].freeze, nil)
    mapping.instance_variable_get(:@key_short_names)[[[:M], false, :long_name]] = 'a'

    assert_raises(Ryac::Pipeline::RenameCollisionError) { mapping.verify_no_shadowing! }
  end

  def test_same_name_on_instance_and_singleton_sides_is_not_a_collision
    mapping = Ryac::MethodRenameMapping.new
    mapping.add_method([[:M], false, :foo].freeze, nil)
    mapping.add_method([[:M], true, :bar].freeze, nil)
    shorts = mapping.instance_variable_get(:@key_short_names)
    shorts[[[:M], false, :foo]] = 'a'
    shorts[[[:M], true, :bar]] = 'a'

    mapping.verify_no_shadowing!
  end
end
