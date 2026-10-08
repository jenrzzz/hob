module AttachmentText
  # pdftotext-style extraction, written by hand: no gem reads a PDF, and
  # hob does not shell out to the real pdftotext. A PDF is objects
  # (`N G obj ... endobj`); a page is one whose dictionary says
  # `/Type /Page`; its content stream(s) (`/Contents`, Flate-decoded when
  # `/Filter /FlateDecode` says so) hold `Tj` and `TJ` operators, which is
  # all this reads. Kerning inside a `TJ` array is ignored, so two runs of
  # the same word can come out stuck together; everything else about the
  # page's layout (columns, tables) is flattened to one stream of text in
  # the order it was drawn. A scanned page has no such operators, so its
  # text comes back empty, which `extract` turns into `text: nil`.
  module Pdf
    class Error < StandardError; end

    OBJECT = /(\d+)\s+\d+\s+obj(.*?)endobj/m
    PAGE_TYPE = %r{/Type\s*/Page(?![A-Za-z])}
    FLATE_FILTER = %r{/Filter\s*(/FlateDecode|\[\s*/FlateDecode)}
    CONTENTS_ARRAY = %r{/Contents\s*\[([^\]]*)\]}m
    CONTENTS_REF = /\/Contents\s+(\d+)\s+\d+\s+R/
    INDIRECT_REF = /(\d+)\s+\d+\s+R/
    SHOW_TEXT = /
      \((?<str>(?:\\.|[^\\()])*)\)\s*Tj
      |\[(?<arr>(?:[^\[\]])*)\]\s*TJ
      |(?<brk>T\*|Td|TD)
    /mx
    PDF_STRING = /\((?:\\.|[^\\()])*\)/

    module_function

    # pages: a 1-based inclusive Range, or nil for the whole document.
    def extract(bytes, pages: nil)
      bytes = bytes.dup.force_encoding(Encoding::BINARY)
      objects = parse_objects(bytes)
      page_nums = objects.select { |_, body| body.match?(PAGE_TYPE) }.keys.sort
      total = page_nums.size

      texts = if page_nums.any?
        page_nums.map { |num| page_text(objects, num) }
      else
        [ objects.filter_map { |_, body| show_text(stream_from(body)) }.join ]
      end
      selected = pages ? texts.values_at(*pages.to_a.map { |n| n - 1 }).compact : texts
      text = selected.join("\n\n").strip

      if text.blank?
        Result.new(text: nil, pages: total.positive? ? total : nil, reason: "no text layer: likely a scan or image-only PDF")
      else
        Result.new(text: text, pages: total.positive? ? total : nil, method: "pdf-text")
      end
    end

    def parse_objects(bytes)
      objects = {}
      bytes.scan(OBJECT) { |num, body| objects[num.to_i] = body }
      objects
    end

    def page_text(objects, num)
      dict, = split_stream(objects[num])
      contents_refs(dict).filter_map { |ref| stream_from(objects[ref]) }.map { |data| show_text(data) }.join
    end

    def contents_refs(dict)
      if (m = dict.match(CONTENTS_ARRAY))
        m[1].scan(INDIRECT_REF).flatten.map(&:to_i)
      elsif (m = dict.match(CONTENTS_REF))
        [ m[1].to_i ]
      else
        []
      end
    end

    # -> [dict text, stream bytes or nil]
    def split_stream(body)
      return [ body, nil ] if body.nil?

      m = body.match(/stream\r?\n/)
      return [ body, nil ] unless m

      rest = body[m.end(0)..]
      endpos = rest.rindex("endstream")
      data = (endpos ? rest[0...endpos] : rest).sub(/[\r\n]+\z/, "")
      [ body[0...m.begin(0)], data ]
    end

    def stream_from(body)
      dict, data = split_stream(body)
      return nil if data.nil?

      dict.match?(FLATE_FILTER) ? Zlib::Inflate.inflate(data) : data
    rescue Zlib::Error
      nil
    end

    def show_text(content)
      return "" if content.nil?

      out = +""
      content.scan(SHOW_TEXT) do
        md = Regexp.last_match
        if md[:str]
          out << decode_string(md[:str])
        elsif md[:arr]
          out << md[:arr].scan(PDF_STRING).map { |s| decode_string(s[1..-2]) }.join
        else
          out << "\n"
        end
      end
      out
    end

    # PDF string escapes: \n \r \t \b \f, \( \) \\, an octal byte \ddd, and
    # a trailing backslash-newline (a line split in the source, not a
    # character). Everything else is taken as a WinAnsi/Latin-1 byte, which
    # is right for ordinary ASCII text and close enough for accented Latin
    # letters; a font with its own encoding can still come out wrong.
    def decode_string(raw)
      bytes = +"".b
      i = 0
      len = raw.bytesize
      while i < len
        c = raw.getbyte(i)
        if c == 92 && i + 1 < len
          nc = raw.getbyte(i + 1)
          case nc
          when 110 then bytes << "\n"; i += 2
          when 114 then bytes << "\r"; i += 2
          when 116 then bytes << "\t"; i += 2
          when 98 then bytes << "\b"; i += 2
          when 102 then bytes << "\f"; i += 2
          when 40, 41, 92 then bytes << nc.chr; i += 2
          when 10 then i += 2
          when 13 then i += (raw.getbyte(i + 2) == 10 ? 3 : 2)
          when 48..55
            oct = raw.byteslice(i + 1, 3)[/\A[0-7]{1,3}/]
            bytes << (oct.to_i(8) & 0xFF).chr
            i += 1 + oct.length
          else
            bytes << nc.chr
            i += 2
          end
        else
          bytes << c.chr
          i += 1
        end
      end
      bytes.force_encoding("Windows-1252").encode("UTF-8", invalid: :replace, undef: :replace)
    end
  end
end
