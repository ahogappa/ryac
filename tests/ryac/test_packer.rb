# frozen_string_literal: true

require_relative '../test_helper'

class TestPacker < Minitest::Test
  include MinifyTestHelper

  SELF_STUB_PIN =
    's=DATA.binmode.read;o="".b;i=0;while i<s.size;f=s.getbyte i;i+=1;' \
    '8.times{break if i>=s.size;if f&1>0;o<<s.getbyte(i);i+=1;else;' \
    'a=s.getbyte i;b=s.getbyte i+1;i+=2;d=(a<<4|b>>4)+1;l=(b&15)+3;' \
    'l.times{o<<o.getbyte(o.size-d)};end;f>>=1};end;' \
    "eval o.force_encoding(\"UTF-8\"),nil,$0\n__END__\n"

  ZLIB_STUB_PIN =
    "require\"zlib\";eval Zlib.inflate(DATA.binmode.read).force_encoding(\"UTF-8\"),nil,$0\n__END__\n"

  def test_stubs_pinned
    assert_equal SELF_STUB_PIN, Ryac::Packer::SELF_STUB
    assert_equal ZLIB_STUB_PIN, Ryac::Packer::ZLIB_STUB
  end

  def test_self_pack_bytes_pinned
    packed = Ryac::Packer.pack('puts "packed hello"', :self)
    assert_equal "#{SELF_STUB_PIN}\xFFputs \"pa\xFFcked hel\alo\"".b, packed
  end

  # A program long enough for real back-references must round-trip through
  # the stub's decoder byte-for-byte: run the packed file and compare.
  PROGRAM = <<~RUBY
    total_counter = 0
    5.times { |i| total_counter += i * i }
    puts total_counter
    puts "total_counter total_counter total_counter"
    puts "日本語の文字列もそのまま"
  RUBY

  def test_self_pack_execution_equivalence
    assert_packed_output_preserved(PROGRAM, :self)
  end

  def test_zlib_pack_execution_equivalence
    assert_packed_output_preserved(PROGRAM, :zlib)
  end

  # The stub evals with $0 as the file name, so the standard launcher guard
  # still fires inside the packed file.
  def test_program_name_guard_fires_inside_pack
    assert_packed_output_preserved(
      "def kickoff = puts(\"launched\")\nkickoff if $PROGRAM_NAME == __FILE__\n", :self
    )
  end

  def test_pack_rejects_data_reader
    error = assert_raises(Ryac::MinifyError) { Ryac::Packer.pack('puts DATA.read', :self) }
    assert_equal 'cannot pack: the program uses DATA, and the self-extracting stub owns the packed file\'s data section',
                 error.message
  end

  def test_pack_rejects_end_marker
    error = assert_raises(Ryac::MinifyError) { Ryac::Packer.pack("puts 1\n__END__\nx", :zlib) }
    assert_equal 'cannot pack: the program uses __END__, and the self-extracting stub owns the packed file\'s data section',
                 error.message
  end

  def test_invalid_format_rejected
    error = assert_raises(ArgumentError) { Ryac::Packer.resolve_format('gzip') }
    assert_equal 'Invalid pack format: gzip (valid: self, zlib)', error.message
  end

  private

  def assert_packed_output_preserved(program, format)
    packed = Ryac::Packer.pack(program, format)
    orig_out, orig_success = run_ruby_code(program)
    packed_out, packed_success = run_ruby_code(packed)
    assert_equal orig_success, packed_success, "Exit status mismatch for #{format} pack"
    assert_equal orig_out, packed_out
  end
end
