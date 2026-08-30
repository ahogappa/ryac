# frozen_string_literal: true

require_relative '../test_helper'

# Byte-offset splicing across the whole pipeline, exercised on text where
# byte and character positions disagree everywhere: multibyte identifiers,
# strings, symbols and regexps. No pinned bytes — the assertion is output
# preservation, so the corpus is free to stress every stage.
class TestMultibyteRoundtrip < Minitest::Test
  include MinifyTestHelper

  CODE = <<~'RUBY'
    module Util
      def self.実行(値:, 倍率: 2)
        値 * 倍率
      end
    end

    class Greeter
      attr_reader :挨拶文

      @@作成数 = 0

      def initialize(name)
        @挨拶文 = "こんにちは、#{name}さん — ようこそ"
        @@作成数 += 1
        $最終作成 = name
      end

      def 挨拶する
        @挨拶文
      end

      def self.作成数
        @@作成数
      end
    end

    パターン = %r{こんにちは、(.+)さん — ようこそ}
    g = Greeter.new("世界")
    メッセージ = g.挨拶する
    puts メッセージ
    puts パターン.match(メッセージ)[1]
    puts g.挨拶文
    puts Greeter.作成数
    puts $最終作成
    puts Util.実行(値: 21)
    puts :記号ですよ
    puts "あ"
  RUBY

  def test_stable_roundtrip
    minify_at_level(CODE, Ryac::Minifier::DEFAULT_LEVEL)
  end

  def test_unstable_roundtrip
    minify_at_level(CODE, :unstable)
  end
end
