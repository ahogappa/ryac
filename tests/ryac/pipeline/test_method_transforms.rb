# frozen_string_literal: true

require_relative '../../test_helper'

class TestMethodTransforms < Minitest::Test
  include MinifyTestHelper

  # All method transform tests share one minify_at_level call (~0.4s TypeProf cost)
  def setup_group
    @group ||= minify_at_level(<<~RUBY, 5, verify_output: false)
      arr = [1, 2, 3]
      puts arr.first
      puts arr.first.to_s
      raise "error" if arr.empty?
      r = (1..10)
      puts r.first
      s = "hello"
      puts s.empty?
      h = { a: 1 }
      puts h.empty?
      puts h.first.inspect
    RUBY
  end

  def test_method_transforms
    result = setup_group
    # raise → fail (method alias), Array#first → [0] (Range/Hash unchanged),
    # Array#empty? → ==[], String#empty? → =="", Hash#empty? → =={}
    assert_equal 'a=[1,2,3];puts a[0];puts a[0].to_s;fail "error" if a==[];b=(1..10);puts b.first;c="hello";puts c=="";d={a:1};puts d=={};puts d.first.inspect', result.code
  end
end
