# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'

class TestDriverFile < Minitest::Test
  SOURCE_PIN = <<~'RUBY'
    # ryac driver. Usage: ruby driver.rb CORE [--exec EXPR] [ARGS...]
    #
    # CORE is a program minified with `ryac --driver`: each file it loads by a
    # computed path is a lambda in RYAC_LAZY, keyed by the path the require
    # builds. ryac_require answers those requires as Ruby would: a file runs
    # once and answers true, a repeat answers false, a file whose run raised
    # can be tried again, and a path no file was bundled under falls through
    # to a real require relative to CORE. Then CORE loads, and EXPR is
    # evaluated at top level with ARGS left in ARGV. Arguments after "--" are
    # never read.
    core = ARGV.shift or abort("usage: ruby #{$0} CORE [--exec EXPR] [ARGS...]")
    stop = ARGV.index("--")
    at = ARGV.index("--exec")
    expr = ARGV.slice!(at, 2)[1] if at && (!stop || at < stop)
    RYAC_CORE = File.expand_path(core)
    def ryac_require(path)
      return require(File.expand_path(path, File.dirname(RYAC_CORE))) unless RYAC_LAZY.key?(path)
      body = RYAC_LAZY[path]
      return false unless body
      RYAC_LAZY[path] = false
      begin
        body.call
      rescue Exception
        RYAC_LAZY[path] = body
        raise
      end
      true
    end
    load RYAC_CORE
    eval(expr, TOPLEVEL_BINDING, "--exec") if expr
  RUBY

  def test_driver_source_pinned
    assert_equal SOURCE_PIN, Ryac::DriverFile::SOURCE
  end

  # The loader keeps Ruby's require contract for the core's regions — once
  # and true, false on a repeat, retryable after a raise — and resolves an
  # unregistered path relative to the core, not to the driver or to the
  # working directory: the driver sits in one directory, the core and its
  # real file in another, and the run starts from a third. The driver's own
  # arguments are gone from ARGV by the time the expression runs.
  def test_driver_runs_the_core_and_answers_its_requires
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, 'tools'))
      Dir.mkdir(File.join(dir, 'app'))
      Dir.mkdir(File.join(dir, 'app', 'plugins'))
      File.write(File.join(dir, 'tools', 'driver.rb'), Ryac::DriverFile::SOURCE)
      File.write(File.join(dir, 'app', 'minify.rb'), <<~'RUBY')
        RYAC_LAZY = {}
        RYAC_LAZY["plugins/once"] = -> { $log << :once }
        RYAC_LAZY["plugins/flaky"] = -> { $tries += 1; raise LoadError, "flaky" if $tries == 1; $log << :flaky }
        $log = []
        $tries = 0
      RUBY
      File.write(File.join(dir, 'app', 'plugins', 'real.rb'), "$log << :real\n")

      expr = <<~'RUBY'
        p ryac_require("plugins/once"), ryac_require("plugins/once")
        first = begin; ryac_require("plugins/flaky"); rescue LoadError => e; e.message; end
        p first, ryac_require("plugins/flaky"), ryac_require("plugins/flaky")
        p ryac_require("plugins/real"), ryac_require("plugins/real")
        p(begin; ryac_require("plugins/missing"); rescue LoadError => e; e.class; end)
        p $log, ARGV
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, 'tools/driver.rb', 'app/minify.rb', '--exec', expr, 'rom.nes', chdir: dir)
      assert status.success?, "the driver failed: #{stderr}"
      assert_equal "true\nfalse\n\"flaky\"\ntrue\nfalse\ntrue\nfalse\nLoadError\n[:once, :flaky, :real]\n[\"rom.nes\"]\n", stdout
    end
  end

  # Without --exec the driver only loads the core; without a core it says
  # how to be run.
  def test_driver_without_an_expression_only_loads_the_core
    Dir.mktmpdir do |dir|
      driver = File.join(dir, 'driver.rb')
      File.write(driver, Ryac::DriverFile::SOURCE)
      File.write(File.join(dir, 'core.rb'), "RYAC_LAZY = {}\nputs :loaded\n")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, driver, 'core.rb', chdir: dir)
      assert status.success?, "the driver failed: #{stderr}"
      assert_equal "loaded\n", stdout

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, driver, chdir: dir)
      assert_equal 1, status.exitstatus
      assert_equal '', stdout
      assert_equal "usage: ruby #{driver} CORE [--exec EXPR] [ARGS...]\n", stderr
    end
  end
end
