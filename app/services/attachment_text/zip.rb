module AttachmentText
  # Just enough of the ZIP format (as docx and odt use it) to pull one entry
  # out by name: the end-of-central-directory record, its central directory
  # (reliable sizes and offsets, unlike a streamed local header), and
  # `inflate` for the one compression method anyone still writes. No gem:
  # Zlib is Ruby's own.
  module Zip
    class Error < StandardError; end

    EOCD = "PK\x05\x06".b
    CENTRAL = "PK\x01\x02".b
    LOCAL = "PK\x03\x04".b

    module_function

    # -> the entry's bytes, or nil when the archive has no entry by that name.
    def read(bytes, path)
      bytes = bytes.dup.force_encoding(Encoding::BINARY)
      eocd = bytes.rindex(EOCD)
      raise Error, "not a zip archive" if eocd.nil?

      count = bytes[eocd + 10, 2].unpack1("v")
      pos = bytes[eocd + 16, 4].unpack1("V")
      count.times do
        raise Error, "a corrupt zip central directory" unless bytes[pos, 4] == CENTRAL

        method = bytes[pos + 10, 2].unpack1("v")
        comp_size = bytes[pos + 20, 4].unpack1("V")
        name_len = bytes[pos + 28, 2].unpack1("v")
        extra_len = bytes[pos + 30, 2].unpack1("v")
        comment_len = bytes[pos + 32, 2].unpack1("v")
        local_offset = bytes[pos + 42, 4].unpack1("V")
        name = bytes[pos + 46, name_len]
        return inflate(bytes, local_offset, method, comp_size) if name == path

        pos += 46 + name_len + extra_len + comment_len
      end
      nil
    end

    def inflate(bytes, offset, method, comp_size)
      raise Error, "a corrupt zip entry" unless bytes[offset, 4] == LOCAL

      name_len = bytes[offset + 26, 2].unpack1("v")
      extra_len = bytes[offset + 28, 2].unpack1("v")
      data = bytes[offset + 30 + name_len + extra_len, comp_size]
      case method
      when 0 then data
      when 8 then Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data)
      else raise Error, "an unsupported zip compression (#{method})"
      end
    rescue Zlib::Error
      raise Error, "a corrupt zip entry"
    end
  end
end
