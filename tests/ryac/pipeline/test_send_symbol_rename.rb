# frozen_string_literal: true

require_relative '../../test_helper'

class TestSendSymbolRename < Minitest::Test
  include MinifyTestHelper

  def test_send_symbol_renamed
    code = <<~RUBY
      class Foo
        def hello_world = "hello"
        def test_it
          send(:hello_world)
        end
      end
      puts Foo.new.test_it
    RUBY
    result = minify_at_level(code, 5)
    assert_equal 'class A;def a ="hello";def b =send :a;end;puts A.new.b', result.code
  end

  def test_public_send_symbol_renamed
    code = <<~RUBY
      class Foo
        def hello_world = "hello"
        def test_it
          public_send(:hello_world)
        end
      end
      puts Foo.new.test_it
    RUBY
    result = minify_at_level(code, 5)
    assert_equal 'class A;def a ="hello";def b =public_send :a;end;puts A.new.b', result.code
  end

  def test_send_with_receiver_symbol_renamed
    code = <<~RUBY
      class Foo
        def hello_world = "hello"
      end
      f = Foo.new
      puts f.send(:hello_world)
    RUBY
    result = minify_at_level(code, 5)
    assert_equal 'class A;def a ="hello";end;a=A.new;puts a.send(:a)', result.code
  end

  def test___send___symbol_renamed
    code = <<~RUBY
      class Foo
        def hello_world = "hello"
        def test_it = __send__(:hello_world)
      end
      puts Foo.new.test_it
    RUBY
    result = minify_at_level(code, 5)
    assert_equal 'class A;def a ="hello";def b =__send__ :a;end;puts A.new.b', result.code
  end

  def test_send_with_dynamic_arg_not_patched
    code = <<~RUBY
      class Foo
        def hello_world = "hello"
        def test_it(name)
          send(name)
        end
      end
      puts Foo.new.test_it(:hello_world)
    RUBY
    result = minify_at_level(code, 5, verify_output: false)
    # send(name) has a variable arg, not a symbol literal — can't patch
    assert_equal 'class A;def b ="hello";def a(a) =send a;end;puts A.new.a(:hello_world)', result.code
  end

  def test_send_and_direct_call_renamed_consistently
    code = <<~RUBY
      class Foo
        def hello_world = "hello"
        def test_direct = hello_world
        def test_send = send(:hello_world)
      end
      f = Foo.new
      puts f.test_direct
      puts f.test_send
    RUBY
    result = minify_at_level(code, 5)
    assert_equal 'class A;def a ="hello";def b =a;def c =send :a;end;a=A.new;puts a.b;puts a.c', result.code
  end

  # One send reaching two *different* method names is a computed dispatch, not
  # polymorphism. Merging them handed one short name to both defs — optcarrot's
  # CPU collapsed 9 addressing modes into a single `k` this way — so both
  # names must survive while ordinary single-target renaming continues.
  def test_computed_dispatch_keeps_every_target_name
    code = <<~RUBY
      class A
        def alpha_mode = "a"
        def beta_mode = "b"
        def run(w)
          send(w ? :alpha_mode : :beta_mode)
        end
      end
      puts A.new.run(true)
      puts A.new.run(false)
    RUBY
    result = minify_at_level(code, 5)
    assert_equal 'class A;def alpha_mode =?a;def beta_mode =?b;def a(a) =send a ? :alpha_mode : :beta_mode;end;' \
                 'puts A.new.a(!!1);puts A.new.a(!1)',
                 result.code
  end
end
