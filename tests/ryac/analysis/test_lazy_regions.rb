# frozen_string_literal: true

require_relative '../../test_helper'

class TestLazyRegions < Minitest::Test
  CODE = "R = {}\n" \
         "R[\"x\"] = -> {\n" \
         "module M; class K; end; end\n" \
         "}\n" \
         "R[\"y\"] = ->(a) { a }\n" \
         "puts 1\n"

  def setup
    @root = Prism.parse(CODE).value
  end

  # Only the parameterless-lambda registration is a region; a lambda that
  # takes parameters is the program's own.
  def test_collect_recognizes_the_registration_shape
    lambdas = Ryac::LazyRegions.collect(@root)
    assert_equal 1, lambdas.size
    assert_equal "-> {\nmodule M; class K; end; end\n}", lambdas.fetch(0).slice
  end

  def test_contains_is_the_lambda_body
    lambdas = Ryac::LazyRegions.collect(@root)
    statements = @root.statements.body
    class_node = statements.fetch(1).arguments.arguments.fetch(1).body.body.fetch(0)
    assert Ryac::LazyRegions.contains?(lambdas, class_node)
    refute Ryac::LazyRegions.contains?(lambdas, statements.fetch(1))
    refute Ryac::LazyRegions.contains?(lambdas, statements.fetch(3))
  end

  # The wrapper after the registry constant becomes spaces (the first of
  # them a statement separator), the closing brace a space; every other byte
  # keeps its position, and the registry constant stays as a statement of
  # its own.
  def test_typeprof_view_blanks_the_wrapper_in_place
    view = Ryac::LazyRegions.typeprof_view(CODE, @root)
    assert_equal "R = {}\n" \
                 "R;           \n" \
                 "module M; class K; end; end\n" \
                 " \n" \
                 "R[\"y\"] = ->(a) { a }\n" \
                 "puts 1\n", view
    assert_equal CODE.bytesize, view.bytesize
    assert Prism.parse(view).success?
  end
end
