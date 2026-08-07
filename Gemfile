# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in ruby-minify.gemspec
gemspec

gem "rake", "~> 13.0"

group :development, :test do
  gem 'debug'
  gem 'minitest'
  gem 'simplecov', require: false
  # Kept on git: the sig/ signatures are written against steep's development
  # branch, and the 2.0.0 release reports hundreds of mismatches against them.
  # Development-only, so it does not constrain anyone installing the gem.
  gem 'steep', github: 'soutaro/steep'
end
