# frozen_string_literal: true

require_relative '../../test_helper'

class TestMethodAliasing < Minitest::Test
  include MinifyTestHelper

  # One TypeProf run covers every RECEIVER_ALIASES row on a proven receiver.
  def receiver_group
    @receiver_group ||= minify_at_level(<<~RUBY, 5, verify_output: false)
      arr = [10, 20]
      puts arr.collect { |v| v }.inspect
      puts arr.collect! { |v| v }.inspect
      puts arr.detect { |v| v > 10 }
      puts arr.find_all { |v| v > 10 }.inspect
      puts arr.collect_concat { |v| [v] }.inspect
      puts arr.find_index(20)
      puts arr.length
      puts arr.entries.inspect
      puts arr.append(30).inspect
      h = { a: 1 }
      h.each_pair { |k, v| puts k }
      puts h.has_key?(:a)
      puts h.has_value?(1)
      puts h.include?(:a)
      puts h.member?(:a)
      puts(-5.magnitude)
      puts :sym.id2name
    RUBY
  end

  # Every RECEIVER_ALIASES row rewritten in one pinned output.
  def test_every_receiver_alias_rewrites_on_a_proven_receiver
    assert_equal 'a=[10,20];puts(a.map{_1}.inspect);puts(a.map!{_1}.inspect);' \
                 'puts(a.find{_1>10});puts(a.select{_1>10}.inspect);' \
                 'puts(a.flat_map{[_1]}.inspect);puts a.index(20);puts a.size;' \
                 'puts a.to_a.inspect;puts a.push(30).inspect;b={a:1};' \
                 'b.each{|c,d|puts c};puts b.key?(:a);puts b.value?(1);' \
                 'puts b.key?(:a);puts b.key?(:a);puts -5.abs;puts :sym.to_s',
                 receiver_group.code
  end

  # Kernel aliases are the only rows allowed to fire without a receiver.
  def test_kernel_aliases_rewrite_receiverless
    result = minify_at_level(<<~RUBY, 5, verify_output: false)
      def check(v)
        raise "bad" if v.nil?
        puts kind_of?(Object)
        puts object_id
        v.yield_self { |x| x }
      end
      check(1)
    RUBY
    assert_equal 'def a(a) =(fail "bad" if a.nil?;puts is_a?(Object);puts __id__;a.then{_1});a 1',
                 result.code
  end

  # Module#include? shares a name with Enumerable#include? but not a
  # meaning; a receiverless include? (dispatching on self) must survive.
  def test_receiverless_include_is_not_rewritten
    result = minify_at_level(<<~RUBY, 5, verify_output: false)
      module Marker
      end
      class Holder
        include Marker
        puts include?(Marker)
      end
    RUBY
    assert_equal 'module A;end;class B;include A;puts include?(A);end', result.code
  end
end
