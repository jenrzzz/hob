require "zlib"
require "nokogiri"

# Local-only text extraction for mail.attachment.get (MAIL.md, "Attachments"):
# turn an attachment's raw bytes into the text a person would read off it,
# entirely on hob's own CPU. No OCR, no gem, no shelling out to pdftotext or
# anything else, and no call anywhere but the mail backend that handed over
# the bytes. A type this cannot read, or a file it cannot make sense of,
# comes back with `text: nil` and a reason — never the raw bytes.
module AttachmentText
  Result = Struct.new(:text, :pages, :method, :reason, keyword_init: true)

  PLAIN = %r{\Atext/(?!html)[\w.+-]*}i
  HTML = %r{\A(text/html|application/xhtml\+xml)\b}i
  PDF = %r{\Aapplication/pdf\b}i
  DOCX = %r{\Aapplication/vnd\.openxmlformats-officedocument\.wordprocessingml\.document\b}i
  ODT = %r{\Aapplication/vnd\.oasis\.opendocument\.text\b}i

  module_function

  # bytes: the attachment's raw content. type: its declared content_type.
  # pages: a 1-based inclusive Range of PDF pages to keep, or nil for all.
  def extract(bytes, type, pages: nil)
    case type.to_s
    when PDF then Pdf.extract(bytes, pages: pages)
    when HTML then Result.new(text: Web.html_text(decode(bytes)), method: "html-text")
    when PLAIN then Result.new(text: decode(bytes), method: "text")
    when DOCX then office(bytes, "word/document.xml", "docx-text")
    when ODT then office(bytes, "content.xml", "odt-text")
    else Result.new(text: nil, reason: "#{type.presence || 'this attachment'} is not a type hob reads as text")
    end
  rescue Zip::Error, Pdf::Error => e
    Result.new(text: nil, reason: e.message)
  end

  def decode(bytes)
    utf8 = bytes.dup.force_encoding("UTF-8")
    return utf8 if utf8.valid_encoding?

    bytes.dup.force_encoding("Windows-1252").encode("UTF-8", invalid: :replace, undef: :replace)
  end

  # docx and odt are both a zip of XML; the readable text is every
  # paragraph's (and heading's) text, in document order.
  def office(bytes, entry_path, method_name)
    xml = Zip.read(bytes, entry_path)
    return Result.new(text: nil, reason: "not a readable #{method_name.split('-').first} file") if xml.nil?

    document = Nokogiri::XML(xml)
    document.remove_namespaces!
    text = document.css("p, h").map(&:text).join("\n").strip
    Result.new(text: text, method: method_name)
  end
end
