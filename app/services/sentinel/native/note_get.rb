module Sentinel
  module Native
    # note.get: one note, all of it.
    class NoteGet < NoteHandler
      CAPABILITY = {
        "name" => "note.get",
        "description" => "Read one of the household's notes in full: its plain `text` (title first), its `html` as Notes keeps " \
                         "it, and its attachments by name (not their contents). A locked (password-protected) note has no text " \
                         "to give: text and html are null. Returns { note: #{FULL_NOTE_SHAPE}, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => NOTE },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Notes.get(arguments))
      end
    end
  end
end
