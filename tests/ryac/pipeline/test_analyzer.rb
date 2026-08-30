# frozen_string_literal: true

require_relative '../../test_helper'

class TestAnalyzer < Minitest::Test
  include MinifyTestHelper

  # --- prism_only_from_string (lines 16,18,19,21,29,74) ---

  def test_prism_only_from_string_returns_analysis_result
    result = Ryac::Pipeline::Analyzer.prism_only_from_string("x = 1\n")
    assert_equal({}, result.scope_mappings)
    assert_nil result.constant_mapping
    assert_equal({}, result.rename_map)
    assert_equal({}, result.method_alias_map)
    assert_equal({}, result.method_transform_map)
    assert_equal "x = 1\n", result.source.content
  end

  # --- prism_only with ConcatenatedSource (line 12) ---

  def test_prism_only_preserves_source
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: "y = 2",
      file_boundaries: [],
      original_size: 5,
      stdlib_requires: [],
      rbs_files: {}
    )
    result = Ryac::Pipeline::Analyzer.prism_only(source)
    assert_equal "y = 2", result.source.content
    assert_equal({}, result.scope_mappings)
  end

  # --- syntax error (lines 85-86) ---

  def test_syntax_error_raises
    source = Ryac::Pipeline::ConcatenatedSource.new(
      content: "def foo(\nend",
      file_boundaries: [],
      original_size: 12,
      stdlib_requires: [],
      rbs_files: {}
    )
    # Inputs are parse-fenced at collection; unparseable text reaching the
    # analyzer means an upstream stage broke it — an internal failure.
    err = assert_raises(Ryac::Pipeline::InvalidOutputError) do
      Ryac::Pipeline::Analyzer.new.call(source)
    end
    assert_equal "minified pre-rename source does not parse (2:0: unexpected 'end'; expected a `)` to close the parameters)", err.message
  end

  # --- rbs_files iteration (line 91) ---

  def test_rbs_files_loaded
    code = "class Calc\n  def add(a, b)\n    a + b\n  end\nend\nputs Calc.new.add(1, 2)\n"
    rbs = "class Calc\n  def add: (Integer, Integer) -> Integer\nend\n"
    result = minify_code(code, rbs_files: { "calc.rbs" => rbs })
    assert_equal "class A;def add(a,b) =a+b;end;puts A.new.add(1,2)", result.code
  end

  # --- defined? with local variable (lines 208-209) ---

  def test_defined_local_variable
    result = minify_code("x = 1\nputs defined?(x)\n")
    assert_equal 'a=1;puts defined?(a)', result.code
  end

  # --- interpolated regex (line 451) ---

  def test_interpolated_regex_with_flags
    result = minify_code("x = \"abc\"\nputs(/\#{x}/i =~ \"abc\")\n")
    assert_equal 'a="abc";puts /#{a}/i=~"abc"', result.code
  end

  # --- for with multi-target index (line 457) ---

  def test_for_multi_target
    result = minify_code("for a, b in [[1,2],[3,4]]\nputs a + b\nend\n")
    assert_equal 'for a, b in [[1,2],[3,4]];puts a+b;end', result.code
  end

  # --- include meta node (line 418) ---

  def test_include_meta_node
    result = minify_code("module M; def hello; puts \"hi\"; end; end\nclass C; include M; end\nC.new.hello\n")
    assert_equal 'module M;def hello =puts "hi";end;class C;include M;end;C.new.hello', result.code
  end

  # --- find patterns ---

  # Find patterns with NAMED splats never crashed any typeprof — the old
  # blanket guard rejected them anyway. They must minify. (The anonymous
  # shapes are covered by the level-test corpus.)
  def test_named_splat_find_pattern_minifies
    result = minify_code("case [1, 2, 3]\nin [*pre, mid, *post]\n  puts mid\nend\n")
    assert_equal 'case [1,2,3];in [*a,b,*c];puts b;end', result.code
  end

  # --- lambda with outer scope variable (lines 227-228, 235-241) ---

  def test_lambda_outer_scope_variable
    result = minify_at_level("def foo\n  x = 1\n  f = ->(a) { puts x }\n  f.call(2)\nend\nfoo\n", Ryac::Minifier::DEFAULT_LEVEL, verify_output: false)
    assert_equal 'def foo =(a=1;b=->(a){puts a};b.(2));foo', result.code
  end
end
