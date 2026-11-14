module Sentinel
  module Native
    # note.append: text added to the end of a note. Nothing already in it is
    # touched, which is why it is a capability of its own: a household can
    # allow it where it would not allow note.update.
    class NoteAppend < NoteHandler
      CAPABILITY = {
        "name" => "note.append",
        "description" => "Add plain text to the end of one of the household's notes, starting on a line of its own; nothing " \
                         "already in the note changes. For adding to a list or a log. A locked note cannot be changed. Returns " \
                         "{ note: #{FULL_NOTE_SHAPE}, notice }. An append that fails as unavailable may still have happened: " \
                         "read the note with note.get before trying again, or it may be there twice.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "id" => NOTE,
            "text" => { "type" => "string", "maxLength" => Notes::MAX_TEXT, "description" => "What to add, as plain text" }
          },
          "required" => %w[id text],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Notes.append(arguments))
      end
    end
  end
end
