# frozen_string_literal: true

require_relative '../../../test_helper'

class TestKeywordCollection < Minitest::Test
  include MinifyTestHelper

  # === L3 group: most verify_output:true tests ===

  L3_GROUP_CODE = [
    'class A;def m(label:);label;end;end;puts A.new.m(label:"x")',
    'class B;def m(label:"default");label;end;end;puts B.new.m',
    'class C;def m(prefix:"",suffix:"");prefix+suffix;end;end;puts C.new.m(prefix:"a",suffix:"b")',
    'class D;def m(value,label:);puts label;value;end;end;puts D.new.m(1,label:"x")',
    'class E;def m(label:);label;end;end;class F<E;def m(label:);super;end;end;puts F.new.m(label:"hi")',
    'class G;def m(label:,**rest);label;end;end;puts G.new.m(label:"x")',
    'class H;def m(label:);label;end;end;h={label:"x"};puts H.new.m(**h)',
    'class I;def m(label:);label;end;end;class J;def m(label:);label;end;end;def kc_f(x)=x.m(label:"hi");kc_f(I.new);kc_f(J.new)',
    'class K;def go(tag:);tag;end;end;puts K.new.go(tag:"x");def kc_h(x)=x.go(tag:"y")',
  ].join(';')

  L3_GROUP_EXPECTED =
    'class A;def m(a:) =a;end;puts A.new.m(a:?x);' \
    'class B;def m(label:"default") =label;end;puts B.new.m;' \
    'class C;def m(a:"",b:"") =a+b;end;puts C.new.m(a:?a,b:?b);' \
    'class D;def m(b,a:) =(puts a;b);end;puts D.new.m(1,a:?x);' \
    'class E;def m(a:) =a;end;class F<E;def m(a:) =super;end;puts F.new.m(a:"hi");' \
    'class G;def m(label:,**a) =label;end;puts G.new.m(label:?x);' \
    'class H;def m(label:) =label;end;a={label:?x};puts H.new.m(**a);' \
    'class I;def m(a:) =a;end;class J;def m(a:) =a;end;def kc_f(a) =a.m(a:"hi");kc_f I.new;kc_f J.new;' \
    'class K;def go(tag:) =tag;end;puts K.new.go(tag:?x);def kc_h(a) =a.go(tag:?y)'

  def l3_group
    @l3_group ||= minify_at_level(L3_GROUP_CODE, 3)
  end

  def test_keyword_renamed
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_keyword_with_default_not_renamed_if_no_savings
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_multiple_keywords_renamed
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_keyword_with_positional
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_super_merges_keyword_groups
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_rest_keywords_excludes_method
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_hash_splat_call_excludes_method
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_polymorphic_call_merges_keyword_groups
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  def test_unresolved_call_excludes_keyword_renaming
    assert_equal L3_GROUP_EXPECTED, l3_group.code
  end

  # === Standalone: `super` into a signature we do not own ===

  # Data.define generates its initializer from the member list, so a `super`
  # forwarding renamed keywords into it raises "unknown keywords: :c, :b, :a".
  # Unlike the class E/F case above, there is no parent def to merge with, so
  # these keywords have to be left alone.
  def test_super_into_generated_initializer_keeps_keywords
    code = "module P\n" \
           "  R = Data.define(:code, :aliases, :preamble) do\n" \
           "    def initialize(code:, aliases: '', preamble: '')\n" \
           "      super\n" \
           "    end\n" \
           "  end\n" \
           "end\n" \
           "puts P::R.new(code: 'x', aliases: 'y', preamble: 'z').code"
    result = minify_at_level(code, 5)
    assert_equal 'module P;R=Data.define(:code,:aliases,:preamble)' \
                 '{def initialize(code:,aliases:"",preamble:"") =super};end;' \
                 'puts P::R.new(code:?x,aliases:?y,preamble:?z).code',
                 result.code
  end

  # === Standalone: zero call count (verify_output: false) ===

  def test_zero_call_count_excludes_method
    code = 'class F;def m(label:);label;end;end'
    result = minify_at_level(code, 3, verify_output: false)
    assert_equal 'class F;def m(label:) =label;end', result.code
  end
end
