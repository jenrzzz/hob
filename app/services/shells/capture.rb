module Shells
  # What a command printed, kept within a limit: the first half of the
  # limit and the last half, with a line between saying how much was left
  # out. A build's first lines say what ran and its last say how it ended;
  # the middle is what goes.
  class Capture
    attr_reader :bytes

    def initialize(limit)
      @head_limit = limit / 2
      @tail_limit = limit - @head_limit
      @head = +"".b
      @tail = +"".b
      @bytes = 0
    end

    def <<(data)
      data = data.to_s.b
      @bytes += data.bytesize
      room = @head_limit - @head.bytesize
      if room.positive?
        @head << data.byteslice(0, room)
        data = data.byteslice(room..) || "".b
      end
      return self if data.empty?

      @tail << data
      @tail = @tail.byteslice(-@tail_limit, @tail_limit) if @tail.bytesize > @tail_limit
      self
    end

    def dropped
      bytes - @head.bytesize - @tail.bytesize
    end

    def truncated?
      dropped.positive?
    end

    def to_s
      return text(@head + @tail) unless truncated?

      "#{text(@head)}\n[... #{dropped} bytes left out ...]\n#{text(@tail)}"
    end

    private

    def text(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8).scrub("�")
    end
  end
end
