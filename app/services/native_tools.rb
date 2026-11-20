# Every tool hob answers itself in a turn (MEMORY.md, "Native tools"):
# memory's recall/remember when the turn's memory scope offers them, and the
# persona's corpora (CorpusTools). ToolExchange.settle_native! asks it
# `native?` and `execute`; ChatTurn and Completion declare its `defs` beside
# the caller's tools, which may not take one of its names.
class NativeTools
  # -> a NativeTools, or nil when the turn has none.
  def self.build(personas:, conversation:, scope:)
    venues = [
      (Memory::Tools.new(scope) if scope&.tools?),
      CorpusTools.build(personas: personas, conversation: conversation)
    ].compact
    venues.any? ? new(venues) : nil
  end

  def initialize(venues)
    @venues = venues
  end

  def names
    @venues.flat_map(&:names)
  end

  def defs
    @venues.flat_map(&:defs)
  end

  def native?(name)
    @venues.any? { |v| v.native?(name) }
  end

  def execute(call, node: nil)
    @venues.find { |v| v.native?(call["name"]) }.execute(call, node: node)
  end

  # The caller's tools plus ours; a caller's tool may not take a native name.
  def declare(tools)
    clash = Array(tools).map { |t| (t["name"] || t[:name]).to_s } & names
    raise Gateway::Invalid, "#{clash.join(', ')} is a native tool in this turn; rename yours" if clash.any?

    Array(tools) + defs
  end
end
