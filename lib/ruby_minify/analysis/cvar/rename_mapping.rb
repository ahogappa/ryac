# frozen_string_literal: true

require_relative '../class_scoped_rename_mapping'

module RubyMinify
  # Renames class variables (@@foo) per class path. See
  # ClassScopedRenameMapping for the shared collection and naming logic.
  class CvarRenameMapping < ClassScopedRenameMapping
    private

    def name_prefix = "@@"
    def keep_threshold = 3
  end
end
