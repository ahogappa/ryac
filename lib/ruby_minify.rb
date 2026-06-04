# frozen_string_literal: true

require 'typeprof'
require 'prism'
require_relative "ruby_minify/ast_utils"
require_relative "ruby_minify/version"
require_relative "ruby_minify/name_generator"
require_relative "ruby_minify/analysis/method_aliases"
require_relative "ruby_minify/analysis/constant/rename_mapping"
require_relative "ruby_minify/analysis/scope_management"
require_relative "ruby_minify/analysis/constant/collection"
require_relative "ruby_minify/analysis/method_aliasing"
require_relative "ruby_minify/union_find"
require_relative "ruby_minify/analysis/class_scoped_rename_mapping"
require_relative "ruby_minify/analysis/method/rename_mapping"
require_relative "ruby_minify/analysis/method/collection"
require_relative "ruby_minify/analysis/ivar/rename_mapping"
require_relative "ruby_minify/analysis/ivar/collection"
require_relative "ruby_minify/analysis/cvar/rename_mapping"
require_relative "ruby_minify/analysis/cvar/collection"
require_relative "ruby_minify/analysis/gvar/rename_mapping"
require_relative "ruby_minify/analysis/gvar/collection"
require_relative "ruby_minify/analysis/keyword/rename_mapping"
require_relative "ruby_minify/analysis/keyword/collection"
require_relative "ruby_minify/minifier"
require_relative "ruby_minify/gem_resolver"

module RubyMinify
  class Error < StandardError; end
  class MinifyError < Error; end
  class SyntaxError < Error; end
end
