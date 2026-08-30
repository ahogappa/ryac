# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in ryac.gemspec
gemspec

# Tracks master: the corpus exercises pattern shapes (anonymous-splat find
# patterns, `**nil`, bare block pipes) that no released typeprof ingests
# yet. Bump the gemspec floor to the next typeprof release when it ships.
gem "typeprof", github: "ruby/typeprof"

gem "rake", "~> 13.0"

group :development, :test do
  gem 'debug'
  gem 'minitest'
  gem 'simplecov', require: false
  # Kept on git: the sig/ signatures are written against steep's development
  # branch, and the 2.0.0 release reports hundreds of mismatches against them.
  # Development-only, so it does not constrain anyone installing the gem.
  #
  # Pinned to a ref rather than tracking master: a later master (faa2c88)
  # makes `steep check` hang instead of finishing in seconds.
  gem 'steep', github: 'soutaro/steep', ref: '1ccd6c7998fb4aaa8f939deeb970f66907e1d747'
end
