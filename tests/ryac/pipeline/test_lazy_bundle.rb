# frozen_string_literal: true

require_relative '../../test_helper'

# The lazy_plugins fixture end to end: a loader that requires
# "plugins/#{name}_video" from inside a method, a plugin whose top-level
# require has no gem behind it, a plugin that requires a sibling helper,
# and a base class whose ivars both plugins write.
class TestLazyBundle < Minitest::Test
  include MinifyTestHelper

  FIXTURE = File.expand_path('../../fixtures/lazy_plugins/main.rb', __dir__)

  def bundle
    @bundle ||= Ryac::Minifier.new.call(FIXTURE, level: :stable)
  end

  # Regions registered ahead of the core, the launch behind its main-script
  # guard (so a runner can load the bundle as a library), the dynamic site and the sibling
  # require pointed at the loader, the plugins' ivars renamed with the base
  # class they subclass, the region-only names (PlainVideo, TurboVideo,
  # SharedHelpers, BRIGHTNESS) kept, boot — an entry point nothing in the
  # bundle calls — kept for a launcher, and the alias block down to the
  # skeleton.
  def test_bundle_pinned
    assert_equal 'B={};def c(a) =(return require_relative(a) if !B.key?(a);b=B[a];return !1 if !b;B[a]=!1;begin;b.();rescue Exception;B[a]=b;fail;end;!!1);' \
                 'B["engine/plugins/shared"]=->{module A;module SharedHelpers;BRIGHTNESS=5;def a(a) =a.map{_1+BRIGHTNESS};end;end};' \
                 'B["engine/plugins/plain_video"]=->{c "engine/plugins/shared";' \
                 'module A;class PlainVideo<A::D;include SharedHelpers;def b =(super;@palette=a(@a);@b<<:plain);end;end};' \
                 'B["engine/plugins/turbo_video"]=->{require "no_such_gem_for_the_ryac_fixture";' \
                 'module A;class TurboVideo<A::D;def b =(super;@palette=@a.map{_1*2});end;end};' \
                 'module A;module C;DB={turbo: :TurboVideo,plain: :PlainVideo};def self.boot(a) =b(a)&.palette;def self.b(a) =begin;c "engine/plugins/#{a}_video";A.const_get(DB.fetch(a)).new :config;rescue LoadError;();end;end;end;' \
                 'module A;class D;def initialize(a) =(@c=a;@a=[10,20,30];@b=[];b);attr :palette;def b =@b<<:base;def tick =@b.size;end;end;' \
                 'if $0==__FILE__;a=A::C.b(:turbo)||A::C.b(:plain);puts a.is_a?(A::PlainVideo);puts a.palette.inspect;puts a.tick;puts A.const_defined?(:TurboVideo);puts A::C.b(:plain).tick;end;' \
                 'Engine=A;A::Loader=A::C;A::Video=A::D',
                 bundle.full_content
    assert_equal 5, bundle.stats.file_count
  end

  # The bundle behaves as the original: the turbo plugin's missing gem
  # raises LoadError inside its region and the loader's caller walks on to
  # the plain plugin, which pulls its shared helper through the loader; a
  # second require of the same plugin is a no-op that still yields the
  # class. TurboVideo never came to exist on either side.
  def test_bundle_runs_like_the_original
    expected = "true\n[15, 25, 35]\n2\nfalse\n2\n"
    original_out, _stderr, original_status = Open3.capture3(RbConfig.ruby, FIXTURE)
    assert original_status.success?
    assert_equal expected, original_out

    bundled_out, bundled_ok = run_ruby_code(bundle.full_content)
    assert bundled_ok, "the bundle failed:\n#{bundled_out}"
    assert_equal expected, bundled_out
  end
end
