# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'fileutils'
require 'rbconfig'
require_relative '../lib/ryac'

# Test that minified gems pass their own test suites.
# Excluded from default `rake test` — run with `rake test:gems`.
class TestGemMinification < Minitest::Test
  GEM_TESTS_DIR = File.expand_path('../gem_tests', __dir__)

  GEMS = {
    sinatra: {
      source: 'sinatra/lib/sinatra/base.rb',
      test_files: %w[
        sinatra/test/routing_test.rb
        sinatra/test/helpers_test.rb
        sinatra/test/settings_test.rb
        sinatra/test/filter_test.rb
        sinatra/test/request_test.rb
        sinatra/test/response_test.rb
        sinatra/test/result_test.rb
        sinatra/test/base_test.rb
        sinatra/test/delegator_test.rb
        sinatra/test/streaming_test.rb
        sinatra/test/middleware_test.rb
        sinatra/test/sinatra_test.rb
        sinatra/test/server_test.rb
        sinatra/test/static_test.rb
        sinatra/test/extensions_test.rb
        sinatra/test/mapped_error_test.rb
        sinatra/test/templates_test.rb
        sinatra/test/route_added_hook_test.rb
        sinatra/test/compile_test.rb
        sinatra/test/host_authorization_test.rb
        sinatra/test/indifferent_hash_test.rb
        sinatra/test/rack_test.rb
        sinatra/test/readme_test.rb
        sinatra/test/erb_test.rb
        sinatra/test/rdoc_test.rb
        sinatra/test/liquid_test.rb
        sinatra/test/encoding_test.rb
        sinatra/test/asciidoctor_test.rb
        sinatra/test/builder_test.rb
        sinatra/test/haml_test.rb
        sinatra/test/markaby_test.rb
        sinatra/test/markdown_test.rb
        sinatra/test/nokogiri_test.rb
        sinatra/test/rabl_test.rb
        sinatra/test/sass_test.rb
        sinatra/test/scss_test.rb
        sinatra/test/slim_test.rb
        sinatra/test/yajl_test.rb
      ],
      lib_name: 'sinatra/base',
      extra_includes: ['sinatra/rack-protection/lib'],
      copy_files: %w[sinatra/lib/sinatra/middleware sinatra/lib/sinatra/version.rb sinatra/lib/sinatra/show_exceptions.rb sinatra/lib/sinatra/indifferent_hash.rb],
    },
    rubocop: {
      source: 'rubocop/lib/rubocop.rb',
      test_file_patterns: ['rubocop/spec/rubocop/**/*_spec.rb'],
      exclude_test_patterns: %w[
        rubocop/spec/rubocop/server/**/*_spec.rb
        rubocop/spec/rubocop/cli/**/*_spec.rb
      ],
      exclude_test_files: %w[
        rubocop/spec/rubocop/cops_documentation_generator_spec.rb
        rubocop/spec/rubocop/runner_spec.rb
        rubocop/spec/rubocop/cli_spec.rb
        rubocop/spec/rubocop/lsp/server_spec.rb
        rubocop/spec/rubocop/mcp/server_spec.rb
        rubocop/spec/rubocop/runner_formatter_invocation_spec.rb
      ],
      lib_name: 'rubocop',
      test_runner: :rspec,
      gem_dir: 'rubocop',
      copy_files: %w[rubocop/lib/rubocop/cop/internal_affairs rubocop/lib/rubocop/cop/internal_affairs.rb rubocop/lib/rubocop/server.rb rubocop/lib/rubocop/server rubocop/lib/rubocop/rspec],
      file_depth: 2,
      project_files: %w[rubocop/config],
    }
  }.freeze

  # The canaries sit outside the supported boundary: :stable's class and
  # variable renaming breaks sinatra and rubocop (registries and reflection),
  # so they run a keyword-only step composition instead — enough pipeline to
  # catch regressions on large real code without asserting a promise the
  # levels don't make.
  CANARY_STAGES = [
    Ryac::Minifier::OPTIMIZE,
    [Ryac::Pipeline::ConstantAliaser],
    [Ryac::Pipeline::AttrDeclShorten],
    [Ryac::Pipeline::VariableRenamer, { features: { keywords: true } }]
  ].freeze

  GEMS.each do |gem_name, config|
    [CANARY_STAGES].each do |level|
      define_method(:"test_#{gem_name}_canary") do
        source_path = File.join(GEM_TESTS_DIR, config[:source])
        test_files = Array(config[:test_files] || config[:test_file]).map { |f| File.join(GEM_TESTS_DIR, f) }
        if config[:test_file_patterns]
          excludes = Array(config[:exclude_test_files]).map { |f| File.join(GEM_TESTS_DIR, f) }
          Array(config[:exclude_test_patterns]).each do |pat|
            excludes.concat(Dir.glob(File.join(GEM_TESTS_DIR, pat)))
          end
          config[:test_file_patterns].each do |pattern|
            test_files.concat(Dir.glob(File.join(GEM_TESTS_DIR, pattern)) - excludes)
          end
          test_files.uniq!
        end
        skip "gem source not found: #{source_path}" unless File.exist?(source_path)
        test_files.each { |f| skip "gem test not found: #{f}" unless File.exist?(f) }

        extra_includes = (config[:extra_includes] || []).map { |p| File.join(GEM_TESTS_DIR, p) }
        copy_files = (config[:copy_files] || []).map { |p| File.join(GEM_TESTS_DIR, p) }
        project_files = (config[:project_files] || []).map { |p| File.join(GEM_TESTS_DIR, p) }
        gem_dir = config[:gem_dir] ? File.join(GEM_TESTS_DIR, config[:gem_dir]) : nil
        assert_minified_gem_passes(
          source_path: source_path,
          test_files: test_files,
          lib_name: config[:lib_name],
          lib_dir: File.join(GEM_TESTS_DIR, File.dirname(config[:source])),
          level: level,
          gem_name: gem_name,
          extra_includes: extra_includes,
          copy_files: copy_files,
          test_runner: config[:test_runner],
          file_depth: config[:file_depth] || 0,
          project_files: project_files,
          gem_dir: gem_dir
        )
      end
    end
  end

  private

  def assert_minified_gem_passes(source_path:, test_files:, lib_name:, lib_dir:, level:, gem_name:, extra_includes: [], copy_files: [], test_runner: nil, file_depth: 0, project_files: [], gem_dir: nil)
    # Run baseline (original code) to find environment-specific failures
    baseline_failures = baseline_failures_for(gem_name, test_files, lib_dir,
                                               extra_includes: extra_includes, test_runner: test_runner, gem_dir: gem_dir)

    minifier = Ryac::Minifier.new
    result = minifier.call(source_path, level: level)

    content = if result.aliases.empty?
      result.content
    else
      "#{result.content};#{result.aliases}"
    end

    Dir.mktmpdir("minify_gem_test") do |tmpdir|
      # file_depth: nest the minified file N levels deep so __FILE__-relative
      # paths (e.g., RUBOCOP_HOME = File.dirname(__FILE__)/../..) resolve correctly
      if file_depth > 0
        nested_dir = File.join(tmpdir, *Array.new(file_depth, 'x'))
        FileUtils.mkdir_p(nested_dir)
        minified_path = File.join(nested_dir, "#{lib_name}.rb")
        actual_lib_dir = nested_dir
      else
        minified_path = File.join(tmpdir, "#{lib_name}.rb")
        actual_lib_dir = tmpdir
      end
      FileUtils.mkdir_p(File.dirname(minified_path))
      File.write(minified_path, content)

      gem_root = File.expand_path('..', File.dirname(source_path))
      project_files.each { |src| copy_relative(src, gem_root, tmpdir) }
      copy_files.each { |src| copy_relative(src, File.dirname(source_path), File.dirname(minified_path)) }
      # Create stub files for require_relative targets in copied files that
      # don't exist (their code is already in the minified output)
      create_require_stubs(File.dirname(minified_path))
      minified = run_gem_tests(test_files, actual_lib_dir, extra_includes: extra_includes, test_runner: test_runner, gem_dir: gem_dir)
      minified_count = parse_test_count(minified[:stdout])
      assert minified_count,
        "#{gem_name} canary: no test summary found (minified code likely crashed)\nstderr: #{minified[:stderr][0, 300]}"
      assert minified_count > 0, "#{gem_name} canary: 0 tests ran"
      minified_failures = parse_test_result(minified[:stdout])
      new_failures = minified_failures - baseline_failures
      assert new_failures.empty?,
        "#{gem_name} canary: #{new_failures.size} new failure(s) (not in baseline):\n#{new_failures.join("\n")}"
    end
  end

  def baseline_failures_for(gem_name, test_files, lib_dir, extra_includes: [], test_runner: nil, gem_dir: nil)
    cache = self.class.baseline_cache
    return cache[gem_name] if cache.key?(gem_name)

    baseline = run_gem_tests(test_files, lib_dir, extra_includes: extra_includes, test_runner: test_runner, gem_dir: gem_dir)
    cache[gem_name] = parse_test_result(baseline[:stdout])
  end

  def self.baseline_cache
    @baseline_cache ||= {}
  end

  def run_gem_tests(test_files, lib_dir, extra_includes: [], test_runner: nil, gem_dir: nil)
    test_files = Array(test_files)
    include_args = ["-I", lib_dir] + extra_includes.flat_map { |p| ["-I", p] }

    if test_runner == :rspec
      args = build_rspec_args(test_files, lib_dir, include_args)
    elsif test_files.size == 1
      args = [*include_args, test_files.first]
    else
      # Multiple test files: use a runner script that keeps lib_dir at the
      # front of $LOAD_PATH even if test helpers prepend their own lib dirs.
      # Without this, gems like sinatra whose test_helper does
      # $LOAD_PATH.unshift(original_lib) would bypass our minified lib.
      runner = Tempfile.new(['gem_test_runner', '.rb'])
      runner.write(<<~RUBY)
        minified_lib = #{lib_dir.inspect}
        original_unshift = $LOAD_PATH.method(:unshift)
        $LOAD_PATH.define_singleton_method(:unshift) do |*args|
          original_unshift.call(*args)
          if $LOAD_PATH.index(minified_lib) != 0
            $LOAD_PATH.delete(minified_lib)
            original_unshift.call(minified_lib)
          end
          self
        end
        #{test_files.map { |f| "require #{f.inspect}" }.join("\n")}
      RUBY
      runner.flush
      args = [*include_args, runner.path]
    end
    # Use temp files instead of Open3.capture3 to avoid pipe buffer
    # deadlocks when test output is very large (e.g. 30k+ rspec examples)
    stdout_file = Tempfile.new('gem_test_stdout')
    stderr_file = Tempfile.new('gem_test_stderr')
    stdout_file.close
    stderr_file.close
    work_dir = if gem_dir
      gem_dir
    elsif test_runner == :rspec
      find_spec_dir(test_files.first) || File.dirname(test_files.first)
    else
      File.dirname(test_files.first)
    end
    pid = Bundler.with_unbundled_env do
      spawn(
        RbConfig.ruby, *args,
        chdir: work_dir,
        out: [stdout_file.path, 'w'],
        err: [stderr_file.path, 'w']
      )
    end
    timeout = test_files.size > 10 ? 600 : 120
    waiter = Thread.new { Process.wait2(pid) }
    if waiter.join(timeout)
      { stdout: File.read(stdout_file.path), stderr: File.read(stderr_file.path), status: waiter.value[1] }
    else
      Process.kill('TERM', pid)
      waiter.join
      { stdout: File.read(stdout_file.path), stderr: "TIMEOUT after #{timeout}s\n" + File.read(stderr_file.path), status: nil }
    end
  ensure
    stdout_file&.unlink
    stderr_file&.unlink
    runner&.close!
    @rspec_runner&.close!
    @rspec_runner = nil
  end

  def build_rspec_args(test_files, lib_dir, include_args)
    spec_dir = find_spec_dir(test_files.first)
    runner = Tempfile.new(['rspec_runner', '.rb'])
    runner.write(<<~RUBY)
      $LOAD_PATH.unshift(#{spec_dir.inspect}) if #{spec_dir.inspect}
      require "rspec/core"
      exit(RSpec::Core::Runner.run(#{test_files.inspect} + ["--format", "progress", "--order", "defined", "--require", "spec_helper"]))
    RUBY
    runner.flush
    @rspec_runner = runner
    [*include_args, runner.path]
  end

  def find_spec_dir(test_file)
    dir = File.dirname(test_file)
    until dir == '/' || dir == '.'
      return dir if File.basename(dir) == 'spec'
      dir = File.dirname(dir)
    end
    nil
  end

  def copy_relative(src, base_from, base_to)
    relative = src.sub(base_from + '/', '')
    dst = File.join(base_to, relative)
    FileUtils.mkdir_p(File.dirname(dst))
    if File.directory?(src)
      FileUtils.cp_r(src, dst)
    else
      FileUtils.cp(src, dst)
    end
  end

  def create_require_stubs(base_dir)
    Dir.glob(File.join(base_dir, '**', '*.rb')).each do |file|
      File.read(file).scan(/require_relative\s+['"]([^'"]+)['"]/).each do |match|
        rel_path = match[0]
        target = File.expand_path(rel_path, File.dirname(file))
        target += '.rb' unless target.end_with?('.rb')
        next if File.exist?(target)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, "# stub: code already in minified output\n")
      end
    end
  end

  def parse_test_count(output)
    # minitest: "5 runs, ..." / test-unit: "27 tests, ..."
    if output =~ /(\d+) (?:runs?|tests?),/
      $1.to_i
    # rspec: "1028 examples, 0 failures"
    elsif output =~ /(\d+) examples?,/
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

    # rspec format: "rspec ./spec/path/file_spec.rb:42 # Description text"
    output.scan(/^rspec (\S+:\d+)/) do |match|
      failures << match[0]
    end

    failures.sort.uniq
  end
end
