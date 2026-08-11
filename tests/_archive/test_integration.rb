# frozen_string_literal: true

require_relative 'test_helper'

class TestIntegration < Minitest::Test
  include MinifyTestHelper

  # ===============================================
  # Self-Hosting Test (Bootstrap Test)
  # ===============================================
  # True self-hosting: minified minifier can minify itself again,
  # and the result is functionally equivalent.

  def test_self_hosting
    require 'open3'

    lib_dir = File.expand_path('../lib', __dir__)
    entry_path = File.join(lib_dir, 'ryac.rb')

    # Step 1: Minify the minifier source using original minifier (multi-file mode)
    original_minifier = Ryac::Minifier.new
    result1 = original_minifier.call(entry_path)

    # Verify minified code is valid Ruby
    require 'prism'
    parse_result = Prism.parse(result1.content)
    assert parse_result.errors.empty?,
           "Minified minifier should be valid Ruby: #{parse_result.errors.map(&:message).join(', ')}"

    Dir.mktmpdir do |tmpdir|
      # Write minified minifier to temp file
      minified_minifier_path = File.join(tmpdir, 'minified_minifier.rb')
      File.write(minified_minifier_path, result1.content)

      # Step 2: Use minified minifier to minify the ORIGINAL source code
      # The minified minifier should produce the same output as the original
      # Note: Module names are shortened by minification, so find the Minifier class dynamically
      runner_code = <<~RUBY
        require '#{minified_minifier_path}'
        klass = ObjectSpace.each_object(Class).find { |c|
          c.method_defined?(:call) &&
          c.method_defined?(:result) &&
          c.instance_method(:call).arity == -2 &&
          c.instance_method(:initialize).arity == 0
        }
        raise "Could not find Minifier class" unless klass
        minifier = klass.new
        result = minifier.call('#{entry_path}')
        puts result.content
      RUBY

      result2_content, stderr, status = Open3.capture3('ruby', '-e', runner_code)

      assert status.success?,
             "Minified minifier should be able to minify original source: #{stderr}"

      # Step 3: Verify output1 == output2 (self-hosting property)
      assert_equal result1.content, result2_content.strip,
             "Minified minifier should produce identical output when minifying original source"

      # Step 4: Re-minification should be idempotent (same size)
      re_minifier = Ryac::Minifier.new
      result3 = re_minifier.call(minified_minifier_path)
      RubyVM::InstructionSequence.compile(result3.content)
      assert_equal result1.content, result3.content,
             "Re-minification should be idempotent " \
             "(first=#{result1.content.bytesize}, re-minified=#{result3.content.bytesize}, " \
             "diff=#{result3.content.bytesize - result1.content.bytesize})"
    end
  end
end
