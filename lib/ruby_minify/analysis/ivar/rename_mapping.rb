# frozen_string_literal: true

require_relative '../class_scoped_rename_mapping'

module RubyMinify
  # Renames instance variables (@foo) per class path. See
  # ClassScopedRenameMapping for the shared collection and naming logic.
  class IvarRenameMapping < ClassScopedRenameMapping
    private

    def name_prefix = "@"
    def keep_threshold = 2
  end
end
