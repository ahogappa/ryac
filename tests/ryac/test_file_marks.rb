# frozen_string_literal: true

require_relative '../test_helper'

class TestFileMarks < Minitest::Test
  MARKS = [
    Ryac::Pipeline::FileMark.new(path: '/app/lib/a.rb', lazy: false),
    Ryac::Pipeline::FileMark.new(path: '/app/lib/b.rb', lazy: true),
    Ryac::Pipeline::FileMark.new(path: '/app/main.rb', lazy: false)
  ].freeze

  def statement(code) = Prism.parse(code).value.statements.body.fetch(0)

  # A marker is the bare call with one integer; anything else — a string,
  # a receiver, another method — is not one.
  def test_statement_and_index_round_trip
    assert_equal '__ryac_mark__ 7', Ryac::FileMarks.statement(7)
    assert_equal 7, Ryac::FileMarks.index(statement(Ryac::FileMarks.statement(7)))
    assert_nil Ryac::FileMarks.index(statement('__ryac_mark__ "7"'))
    assert_nil Ryac::FileMarks.index(statement('x.__ryac_mark__ 7'))
    assert_nil Ryac::FileMarks.index(statement('__ryac_mark__ 7, 8'))
    assert_nil Ryac::FileMarks.index(statement('puts 7'))
  end

  # Each file's text runs from its marker to the next; the separators
  # around a marker go with it, an empty file is an empty string, and the
  # last file runs to the end of the text.
  def test_split_cuts_at_the_markers
    code = '__ryac_mark__ 0;class A;end;X=1;__ryac_mark__ 1;__ryac_mark__ 2;require_relative "lib/a";puts A'
    assert_equal({ '/app/lib/a.rb' => 'class A;end;X=1', '/app/lib/b.rb' => '',
                   '/app/main.rb' => 'require_relative "lib/a";puts A' },
                 Ryac::FileMarks.split(code, MARKS))
  end

  def test_split_refuses_a_lost_marker
    error = assert_raises(Ryac::InternalError) do
      Ryac::FileMarks.split('__ryac_mark__ 0;class A;end;__ryac_mark__ 2;puts 1', MARKS)
    end
    assert_equal 'split layout lost a file marker: found [0, 2] of 3', error.message
  end

  # A lazy file's span runs from its marker to the next marker, or past the
  # end of the text for the last file; LazyRegions counts those spans with
  # the registrations' lambda bodies.
  def test_lazy_spans_and_regions
    code = "__ryac_mark__ 0\nclass A;end\n__ryac_mark__ 1\nclass B;end\n__ryac_mark__ 2\nputs 1\n"
    root = Prism.parse(code).value
    assert_equal [[28, 56]], Ryac::FileMarks.lazy_spans(root, MARKS, code.bytesize)

    all_lazy = MARKS.map { |mark| mark.with(lazy: true) }
    assert_equal [[0, 28], [28, 56], [56, code.bytesize + 1]], Ryac::FileMarks.lazy_spans(root, all_lazy, code.bytesize)

    mixed = "R[\"x\"] = -> {\nclass C;end\n}\n#{code}"
    mixed_root = Prism.parse(mixed).value
    spans = Ryac::LazyRegions.spans(mixed_root, MARKS, mixed.bytesize)
    assert_equal [[12, 26], [56, 84]], spans
    statements = mixed_root.statements.body
    inside_lambda = statements.fetch(0).arguments.arguments.fetch(1).body.body.fetch(0)
    assert_equal [true, false, true, false],
                 [inside_lambda, statements.fetch(2), statements.fetch(4), statements.fetch(6)].map { |node| Ryac::LazyRegions.contains?(spans, node) }
  end
end
