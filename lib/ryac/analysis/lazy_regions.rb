# frozen_string_literal: true

module Ryac
  # A file the program loads at runtime through a dynamic require
  # (optcarrot's `require_relative "driver/#{name}_#{type}"`) is bundled by
  # the Concatenator as a registration:
  #
  #   RYAC_LAZY["optcarrot/driver/sdl2_video"] = -> { <the file> }
  #
  # The lambda is the file's schedule and nothing more: its body runs when
  # the original require would have, so a `require "ffi"` or `ffi_lib
  # "SDL2"` at the file's top level keeps its optional-dependency timing.
  # For analysis the body is ordinary code in the closed world — one rename
  # table across the core and the files that subclass it.
  #
  # Two things about a region are special. TypeProf does not register a
  # class defined inside a block, so it is handed a view of the source with
  # the wrapper bytes blanked (typeprof_view): every byte of the body keeps
  # its position, and the body reads as the top-level code it becomes when
  # it runs. And a region does not exist at boot: a constant it alone
  # defines cannot be aliased at the end of the file, and an external
  # constant it references cannot be hoisted into the preamble.
  #
  # Regions are recognized by shape — a top-level `Const["key"] = -> { ... }`
  # statement with a parameterless lambda — not by the registry's name,
  # which the aliaser renames like any other constant. Reading a program's
  # own statement of that shape as a region is safe: every consequence keeps
  # more names, never fewer.
  module LazyRegions
    module_function

    # The lambdas of every registration, in source order.
    def collect(prism_root)
      lambdas = [] #: Array[Prism::LambdaNode]
      each_registration(prism_root) { |_statement, lambda_node| lambdas << lambda_node }
      lambdas
    end

    def contains?(lambdas, node)
      offset = node.location.start_offset
      lambdas.any? { |lam| offset > lam.opening_loc.start_offset && offset < lam.closing_loc.start_offset }
    end

    # The source as TypeProf must read it: each registration's wrapper —
    # `["key"] = -> {` after the registry constant, and the closing `}` —
    # replaced by spaces, newlines kept, so the body sits at top level at
    # its original byte positions. The registry constant stays, as its own
    # statement: it is a reference the aliaser renames like any other, and
    # it has to be renamed at the registration too.
    def typeprof_view(content, prism_root)
      bytes = content.b
      each_registration(prism_root) do |statement, lambda_node|
        # statement.receiver is the registry constant (registration_lambda)
        from = statement.receiver.location.end_offset # steep:ignore NoMethod
        blank(bytes, from, lambda_node.opening_loc.end_offset)
        bytes.setbyte(from, 0x3b)
        blank(bytes, lambda_node.closing_loc.start_offset, lambda_node.closing_loc.end_offset)
      end
      bytes.force_encoding(content.encoding)
    end

    def each_registration(prism_root)
      prism_root.statements.body.each do |statement|
        lambda_node = registration_lambda(statement)
        yield statement, lambda_node if lambda_node
      end
    end

    def registration_lambda(statement)
      return nil unless statement.is_a?(Prism::CallNode) && statement.name == :[]=
      return nil unless statement.receiver.is_a?(Prism::ConstantReadNode)

      args = statement.arguments&.arguments
      return nil unless args && args.size == 2

      key, value = args
      return nil unless key.is_a?(Prism::StringNode) && value.is_a?(Prism::LambdaNode)
      return nil if value.parameters

      value
    end

    def blank(bytes, from, to)
      (from...to).each { |i| bytes.setbyte(i, 0x20) unless bytes.getbyte(i) == 0x0a }
    end
  end
end
