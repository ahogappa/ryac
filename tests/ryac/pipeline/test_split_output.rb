# frozen_string_literal: true

require_relative '../../test_helper'
require 'tmpdir'
require 'fileutils'

# The split layout end to end: a fixture minified as one closed world and
# written back as files, then loaded from that tree the way the original
# is loaded from its own.
class TestSplitOutput < Minitest::Test
  include MinifyTestHelper

  FIXTURES = File.expand_path('../../fixtures', __dir__)

  def split(entry)
    Ryac::Minifier.new.split(File.join(FIXTURES, entry), level: :stable)
  end

  def write(result, dir)
    result.files.each do |path, text|
      target = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, text)
    end
  end

  def run_in(dir, *args)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, *args, chdir: dir)
    assert status.success?, "the split program failed: #{stderr}"
    stdout
  end

  # The dynamic require stays a real require_relative, its interpolated
  # local renamed with the rest; the plugins are files again, renamed with
  # the base class they subclass, their own requires in place; the entry
  # ends in the aliases, and its main-script guard fires when it is run.
  def test_lazy_plugins_split
    result = split('lazy_plugins/main.rb')
    files = result.files
    assert_equal %w[engine/loader.rb main.rb engine/plugins/shared.rb engine/plugins/plain_video.rb engine/plugins/turbo_video.rb],
                 files.keys
    assert_equal <<~'RUBY', files['engine/loader.rb']
      module A;module B;DB={turbo: :TurboVideo,plain: :PlainVideo};def self.boot(a) =b(a)&.palette;def self.b(a) =begin;require_relative "plugins/#{a}_video";A.const_get(DB.fetch(a)).new :config;rescue LoadError;();end;end;end
    RUBY
    assert_equal <<~'RUBY', files['main.rb']
      require_relative "engine/loader";module A;class C;def initialize(a) =(@c=a;@a=[10,20,30];@b=[];b);attr :palette;def b =@b<<:base;def tick =@b.size;end;end;if $0==__FILE__;a=A::B.b(:turbo)||A::B.b(:plain);puts a.is_a?(A::PlainVideo);puts a.palette.inspect;puts a.tick;puts A.const_defined?(:TurboVideo);puts A::B.b(:plain).tick;end;Engine=A;A::Loader=A::B;A::Video=A::C
    RUBY
    assert_equal <<~'RUBY', files['engine/plugins/shared.rb']
      module A;module SharedHelpers;BRIGHTNESS=5;def a(a) =a.map{_1+BRIGHTNESS};end;end
    RUBY
    assert_equal <<~'RUBY', files['engine/plugins/plain_video.rb']
      require_relative "shared";module A;class PlainVideo<A::C;include SharedHelpers;def b =(super;@palette=a(@a);@b<<:plain);end;end
    RUBY
    assert_equal <<~'RUBY', files['engine/plugins/turbo_video.rb']
      require "no_such_gem_for_the_ryac_fixture";module A;class TurboVideo<A::C;def b =(super;@palette=@a.map{_1*2});end;end
    RUBY
    assert_equal [1694, 919, 5], [result.stats.original_size, result.stats.minified_size, result.stats.file_count]

    Dir.mktmpdir do |dir|
      write(result, dir)
      assert_equal "true\n[15, 25, 35]\n2\nfalse\n2\n", run_in(dir, 'main.rb')
    end
  end

  # A static tree: each file keeps its require_relative lines and its
  # place; the uncalled public surface (sanitize, wrap, run, version) keeps
  # its names for the caller outside, and the entry ends in the full alias
  # block.
  def test_multi_file_split
    result = split('multi_file/entry.rb')
    files = result.files
    assert_equal %w[lib/nested/dependency_c.rb lib/dependency_a.rb lib/dependency_b.rb entry.rb], files.keys
    assert_equal <<~'RUBY', files['lib/nested/dependency_c.rb']
      module C;J="0.1";class G;def a(a) =a.to_s.strip;def sanitize(a) =a.to_s.gsub(/[^a-zA-Z0-9\s]/,"");end;end
    RUBY
    assert_equal <<~'RUBY', files['lib/dependency_a.rb']
      require_relative "nested/dependency_c";module A;H="1.0";class E;def initialize =@a=C::G.new;def a(a) =(b=@a.a a;c b);private;def c(a) =a.to_s.upcase;end;end
    RUBY
    assert_equal <<~'RUBY', files['lib/dependency_b.rb']
      module B;I="2.0";class F;def a(a) ="[FORMATTED] #{a}";def wrap(a,b,c) ="#{b}#{a}#{c}";end;end
    RUBY
    assert_equal <<~'RUBY', files['entry.rb']
      require_relative "lib/dependency_a";require_relative "lib/dependency_b";module D;class K;def initialize =(@a=A::E.new;@b=B::F.new);def run(a) =(b=@a.a a;@b.a b);def version ="#{A::H}.#{B::I}";end;end;DependencyA=A;DependencyB=B;DependencyC=C;MyApplication=D;A::Processor=A::E;A::VERSION=A::H;B::Formatter=B::F;B::VERSION=B::I;C::Helper=C::G;C::VERSION=C::J;D::Main=D::K
    RUBY
    assert_equal [1366, 727, 4], [result.stats.original_size, result.stats.minified_size, result.stats.file_count]

    Dir.mktmpdir do |dir|
      write(result, dir)
      assert_equal "[FORMATTED] X\n1.0.2.0\n",
                   run_in(dir, '-e', 'require "./entry"; m = MyApplication::Main.new; puts m.run(" x "), m.version')
    end
  end

  # A require inside a class body stays where it is instead of being
  # inlined, and the file it names is written next to it. `self.class.name`
  # is Module#name and keeps its spelling; what it returns is the renamed
  # class, so the program prints the short name.
  def test_in_class_require_split
    result = split('multi_file/in_class_require/widget.rb')
    files = result.files
    assert_equal %w[widget/helper.rb widget.rb], files.keys
    assert_equal <<~'RUBY', files['widget/helper.rb']
      class A;class B;def self.a(a) ="[#{a}]";end;end
    RUBY
    assert_equal <<~'RUBY', files['widget.rb']
      class C;def a =self.class.name;end;class A<C;require_relative "widget/helper";def display =B.a a;end;Base=C;Widget=A;A::Helper=A::B
    RUBY
    assert_equal [309, 180, 2], [result.stats.original_size, result.stats.minified_size, result.stats.file_count]

    Dir.mktmpdir do |dir|
      write(result, dir)
      assert_equal "[A]\n", run_in(dir, '-e', 'require "./widget"; puts Widget.new.display')
    end
  end

  # An autoload keeps its line, and the constant it names keeps its
  # spelling on both sides, so the lazy load still finds it.
  def test_autoload_split
    result = split('multi_file/autoload_test/main.rb')
    files = result.files
    assert_equal %w[helper.rb main.rb], files.keys
    assert_equal <<~'RUBY', files['helper.rb']
      module A;class Helper;def greet ="hello";end;end
    RUBY
    assert_equal <<~'RUBY', files['main.rb']
      module A;autoload :Helper,"./helper";end;AutoloadTest=A
    RUBY
    assert_equal [198, 105, 2], [result.stats.original_size, result.stats.minified_size, result.stats.file_count]

    Dir.mktmpdir do |dir|
      write(result, dir)
      assert_equal "hello\n", run_in(dir, '-e', 'require "./main"; puts AutoloadTest::Helper.new.greet')
    end
  end

  def test_split_needs_a_single_entry
    entries = %w[independent_a.rb independent_b.rb].map { |name| File.join(FIXTURES, 'multi_file', name) }
    error = assert_raises(Ryac::MinifyError) { Ryac::Minifier.new.split(entries, level: :stable) }
    assert_equal 'split output needs a single entry file', error.message
  end
end
