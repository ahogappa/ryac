# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tempfile'
require 'fileutils'
require 'rbconfig'
require_relative '../lib/ryac'

# Test that minified gems pass their own test suites.
# Excluded from default `rake test` — run with `rake test:gems`.
#
# Strategy: run the gem's test suite unminified first to establish a baseline,
# then run minified and assert no NEW failures are introduced.
class TestGemMinification < Minitest::Test
  GEM_TESTS_DIR = File.expand_path('../gem_tests', __dir__)

  GEMS = {
    tsort: {
      source: 'tsort/lib/tsort.rb',
      test_file: 'tsort/test/test_tsort.rb',
      lib_name: 'tsort',
      max_level: 4,
      expected_tests: 8
    },
    observer: {
      source: 'observer/lib/observer.rb',
      test_file: 'observer/test/test_observer.rb',
      lib_name: 'observer',
      expected_tests: 1
    },
    ostruct: {
      source: 'ostruct/lib/ostruct.rb',
      test_file: 'ostruct/test/ostruct/test_ostruct.rb',
      lib_name: 'ostruct',
      max_level: 4,
      expected_tests: 37
    },
    prettyprint: {
      source: 'prettyprint/lib/prettyprint.rb',
      test_file: 'prettyprint/test/test_prettyprint.rb',
      lib_name: 'prettyprint',
      max_level: 4,
      expected_tests: 32
    },
    lint_roller: {
      source: 'lint_roller/lib/lint_roller.rb',
      test_file: 'lint_roller/test/lint_roller_test.rb',
      lib_name: 'lint_roller',
      extra_includes: ['lint_roller/test'],
      expected_tests: 1
    },
    singleton: {
      source: 'singleton/lib/singleton.rb',
      test_file: 'singleton/test/test_singleton.rb',
      lib_name: 'singleton',
      max_level: 4,
      expected_tests: 13
    },
    abbrev: {
      source: 'abbrev/lib/abbrev.rb',
      test_file: 'abbrev/test/test_abbrev.rb',
      lib_name: 'abbrev',
      expected_tests: 2
    },
    mutex_m: {
      source: 'mutex_m/lib/mutex_m.rb',
      test_file: 'mutex_m/test/test_mutex_m.rb',
      lib_name: 'mutex_m',
      expected_tests: 9
    },
    base64: {
      source: 'base64/lib/base64.rb',
      test_file: 'base64/test/base64/test_base64.rb',
      lib_name: 'base64',
      max_level: 4,
      expected_tests: 9
    },
    shellwords: {
      source: 'shellwords/lib/shellwords.rb',
      test_file: 'shellwords/test/test_shellwords.rb',
      lib_name: 'shellwords',
      expected_tests: 11
    },
    securerandom: {
      source: 'securerandom/lib/securerandom.rb',
      test_file: 'securerandom/test/test_securerandom.rb',
      lib_name: 'securerandom',
      expected_tests: 3
    }
  }.freeze

  GEMS.each do |gem_name, config|
    max_level = config[:max_level] || 5
    (0..max_level).each do |level|
      define_method(:"test_#{gem_name}_level#{level}") do
        source_path = File.join(GEM_TESTS_DIR, config[:source])
        test_file = File.join(GEM_TESTS_DIR, config[:test_file])
        skip "gem source not found: #{source_path}" unless File.exist?(source_path)
        skip "gem test not found: #{test_file}" unless File.exist?(test_file)

        extra_includes = (config[:extra_includes] || []).map { |p| File.join(GEM_TESTS_DIR, p) }
        assert_minified_gem_no_regressions(
          source_path: source_path,
          test_file: test_file,
          lib_name: config[:lib_name],
          lib_dir: File.join(GEM_TESTS_DIR, File.dirname(config[:source])),
          level: level,
          gem_name: gem_name,
          extra_includes: extra_includes,
          expected_tests: config[:expected_tests]
        )
      end
    end
  end

  private

  def assert_minified_gem_no_regressions(source_path:, test_file:, lib_name:, lib_dir:, level:, gem_name:, extra_includes: [], expected_tests: nil)
    baseline = run_gem_tests(test_file, lib_dir, extra_includes: extra_includes)
    baseline_count = parse_test_count(baseline[:stdout])
    assert baseline_count, "#{gem_name} baseline: no test summary found in output\nstderr: #{baseline[:stderr][0, 300]}"
    assert baseline_count > 0, "#{gem_name} baseline: 0 tests ran"
    if expected_tests
      assert_equal expected_tests, baseline_count,
        "#{gem_name} baseline: expected #{expected_tests} tests but got #{baseline_count}"
    end
    baseline_failures = parse_test_result(baseline[:stdout])

    minifier = Ryac::Minifier.new
    result = minifier.call(source_path, level: level)

    content = if result.aliases.empty?
      result.content
    else
      "#{result.content};#{result.aliases}"
    end

    Dir.mktmpdir("minify_gem_test") do |tmpdir|
      File.write(File.join(tmpdir, "#{lib_name}.rb"), content)
      minified = run_gem_tests(test_file, tmpdir, extra_includes: extra_includes)
      minified_count = parse_test_count(minified[:stdout])
      assert minified_count,
        "#{gem_name} L#{level}: no test summary found (minified code likely crashed)\nstderr: #{minified[:stderr][0, 300]}"
      assert_equal baseline_count, minified_count,
        "#{gem_name} L#{level}: test count changed (#{baseline_count} → #{minified_count}), some tests may have crashed"
      minified_failures = parse_test_result(minified[:stdout])

      new_failures = minified_failures - baseline_failures
      assert new_failures.empty?,
        "#{gem_name} L#{level} introduced #{new_failures.size} new failure(s):\n" \
        "#{new_failures.join("\n")}\n\nFull output:\n#{minified[:stdout]}\n#{minified[:stderr]}"
    end
  end

  def run_gem_tests(test_file, lib_dir, extra_includes: [])
    include_args = ["-I", lib_dir] + extra_includes.flat_map { |p| ["-I", p] }
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(
        RbConfig.ruby, *include_args, test_file,
        chdir: File.dirname(test_file)
      )
    end
    { stdout: stdout, stderr: stderr, status: status }
  end

  def parse_test_count(output)
    # minitest: "5 runs, ..." / test-unit: "27 tests, ..."
    if output =~ /(\d+) (?:runs?|tests?),/
      $1.to_i
    end
  end

  def parse_test_result(output)
    failures = []

    # test/unit format: "Failure: test_name(ClassName)" or "Error: test_name(ClassName): ..."
    output.scan(/^(?:Failure|Error): (\S+)\((\S+)\)/) do |test_name, klass|
      failures << "#{klass}##{test_name}"
    end

    # minitest format: "  1) Failure:\nTestClass#test_name [path:line]:"
    output.scan(/^\s+\d+\) (?:Failure|Error):\n(\S+#\S+)/) do |match|
      failures << match[0]
    end

    failures.sort.uniq
  end
end
