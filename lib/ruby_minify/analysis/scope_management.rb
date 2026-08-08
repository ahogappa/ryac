# frozen_string_literal: true

module RubyMinify
  # Two different variables of one scope collapsing into one name silently
  # changes what the code computes, and the result still parses — the
  # self-hosted minifier once emitted `def c(a) = c(a) || d(a)` this way. Every
  # scope mapping passes through here before it is used, so a collision fails
  # the run instead of shipping.
  #
  # Its own module so LocalScopes can include just this: including all of
  # RubyMinify would graft dozens of mixin methods onto it as ancestors, which
  # under self-hosting entangles its rename groups with the mixin's.
  module RenameInvariants
    def verify_injective!(mapping, scope_label)
      return if mapping.size < 2

      collisions = mapping.group_by { |_, short| short }
                          .filter_map { |short, pairs| [short, pairs.map(&:first)] if pairs.size > 1 }
      return if collisions.empty?

      raise Pipeline::RenameCollisionError.new(scope_label, collisions)
    end
  end

  include RenameInvariants
end
