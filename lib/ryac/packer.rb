# frozen_string_literal: true

module Ryac
  # Self-extracting output encoding, applied after minification. The emitted
  # file is a short plain-Ruby stub followed by the real program compressed
  # after __END__; running it inflates the bytes and evals them with $0 as
  # the file name, so a `$PROGRAM_NAME == __FILE__` launcher still fires and
  # relative requires resolve as they would from the plain artifact.
  #
  # This is an output format, not a stage: stages rewrite Ruby into
  # equivalent Ruby and re-parse to a fixed point, while a packed file is
  # opaque bytes. Two formats:
  #
  #   :self — an LZSS decoder (4KB window, 3..18-byte matches) inlined in
  #           the stub; no require at all, runs on any Ruby.
  #   :zlib — deflate via the zlib default gem; smaller, but dead on a Ruby
  #           built without it.
  module Packer
    FORMATS = %i[self zlib].freeze

    SELF_STUB = 's=DATA.binmode.read;o="".b;i=0;while i<s.size;f=s.getbyte i;i+=1;' \
                '8.times{break if i>=s.size;if f&1>0;o<<s.getbyte(i);i+=1;else;' \
                'a=s.getbyte i;b=s.getbyte i+1;i+=2;d=(a<<4|b>>4)+1;l=(b&15)+3;' \
                'l.times{o<<o.getbyte(o.size-d)};end;f>>=1};end;' \
                'eval o.force_encoding("UTF-8"),nil,$0' \
                "\n__END__\n"

    ZLIB_STUB = 'require"zlib";eval Zlib.inflate(DATA.binmode.read).force_encoding("UTF-8"),nil,$0' \
                "\n__END__\n"

    def self.resolve_format(value)
      format = value.to_sym
      return format if FORMATS.include?(format)

      raise ArgumentError, "Invalid pack format: #{value} (valid: #{FORMATS.join(', ')})"
    end

    def self.pack(source, format)
      reject_data_readers(source)
      case resolve_format(format)
      when :zlib
        require 'zlib'
        ZLIB_STUB.b + Zlib::Deflate.deflate(source, Zlib::BEST_COMPRESSION)
      else
        SELF_STUB.b + lzss_compress(source)
      end
    end

    # The stub consumes the packed file's one __END__/DATA stream, so a
    # program carrying its own data section or reading DATA would read
    # compressed garbage instead.
    def self.reject_data_readers(source)
      result = Prism.parse(source)
      offending = result.data_loc ? '__END__' : nil
      unless offending
        AstUtils.each_node(result.value) do |node|
          case node
          when Prism::ConstantReadNode
            offending = 'DATA' if node.name == :DATA
          when Prism::ConstantPathNode
            offending = 'DATA' if node.parent.nil? && node.name == :DATA
          end
          break if offending
        end
      end
      return unless offending

      raise MinifyError, "cannot pack: the program uses #{offending}, and the self-extracting stub owns the packed file's data section"
    end

    # Greedy LZSS: flag byte per 8 tokens (1 bit = literal), matches encoded
    # as 12-bit distance-1 / 4-bit length-3. The decoder in SELF_STUB is the
    # exact inverse.
    def self.lzss_compress(data)
      n = data.bytesize
      out = +''.b
      index = Hash.new { |h, k| h[k] = [] } #: Hash[String, Array[Integer]]
      i = 0
      flags = 0
      nflag = 0
      chunk = +''.b
      flush = lambda do
        out << flags.chr << chunk
        flags = 0
        nflag = 0
        chunk = +''.b
      end
      while i < n
        best_len = 0
        best_dist = 0
        if i + 3 <= n
          index[data.byteslice(i, 3) || ''].reverse_each do |j|
            d = i - j
            break if d > 4096

            l = 0
            l += 1 while l < 18 && i + l < n && data.getbyte(j + l) == data.getbyte(i + l)
            if l > best_len
              best_len = l
              best_dist = d
              break if l == 18
            end
          end
        end
        if best_len >= 3
          dm = best_dist - 1
          chunk << (dm >> 4).chr << (((dm & 15) << 4) | (best_len - 3)).chr
          best_len.times do
            index[data.byteslice(i, 3) || ''] << i if i + 3 <= n
            i += 1
          end
        else
          flags |= (1 << nflag)
          # getbyte(i) is non-nil for every i < n
          chunk << data.getbyte(i).chr # steep:ignore NoMethod
          index[data.byteslice(i, 3) || ''] << i if i + 3 <= n
          i += 1
        end
        nflag += 1
        flush.call if nflag == 8
      end
      flush.call if nflag.positive?
      out
    end
    private_class_method :lzss_compress
  end
end
