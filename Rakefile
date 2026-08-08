# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.test_files = FileList["tests/**/test_*.rb"].exclude("tests/test_integration.rb", "tests/test_fixtures.rb", "tests/test_gem_minification.rb", "tests/test_optcarrot.rb", "tests/_archive/**/*")
end

Rake::TestTask.new("test:all") do |t|
  t.libs << "lib"
  t.test_files = FileList["tests/**/test_*.rb"].exclude("tests/test_fixtures.rb", "tests/test_gem_minification.rb", "tests/test_optcarrot.rb", "tests/_archive/**/*")
end

Rake::TestTask.new("test:integration") do |t|
  t.libs << "lib"
  t.test_files = FileList["tests/test_integration.rb"]
end

Rake::TestTask.new("test:gems") do |t|
  t.libs << "lib"
  t.test_files = FileList["tests/test_gem_minification.rb"]
end

desc "Minify optcarrot at the supported level and compare rendered frames"
Rake::TestTask.new("test:optcarrot") do |t|
  t.libs << "lib"
  t.test_files = FileList["tests/test_optcarrot.rb"]
end

desc "Show self-hosting compression ratio"
task :benchmark do
  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "ruby_minify"

  entry_path = File.join(__dir__, "lib", "ruby_minify.rb")
  minifier = RubyMinify::Minifier.new
  result = minifier.call(entry_path)
  stats = result.stats
  compression = ((1 - stats.compression_ratio) * 100).round(1)
  puts "#{stats.file_count} files: #{stats.original_size} -> #{stats.minified_size} bytes (#{compression}% reduction)"
end

task default: :test
