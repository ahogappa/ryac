# frozen_string_literal: true

module Ryac
  # The two-file layout of a program with lazy regions: the minified program
  # as a library — the registry with its regions, the core and the aliases,
  # nothing that runs and no loader — and the driver, the same file for every
  # program, which supplies the loader the core's dynamic requires call,
  # loads the core and starts it with an expression from its command line:
  #
  #   ruby driver.rb minify.rb --exec "Optcarrot::NES.new.run" game.nes
  #
  # The driver speaks two names, Concatenator::REGISTRY_NAME and
  # Concatenator::LOADER_NAME; a core minified for it keeps them (the
  # registry is pinned in the analyzer, the loader is not defined in the
  # core at all) and renames everything else as usual. The driver strips its
  # own arguments before anything else reads ARGV, so the program's option
  # parsing sees only what follows. Defining the loader before the load
  # means a dynamic require the core runs while loading finds its region
  # too.
  module DriverFile
    SOURCE = <<~'RUBY'
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
  end
end
