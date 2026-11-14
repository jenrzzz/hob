module Sentinel
  module Native
    # note.update: rename, rewrite, or move a note. `text` and `html` replace
    # what was there, and Notes keeps no history an agent could restore it
    # from, so a household may well allow note.append and not this.
    class NoteUpdate < NoteHandler
      CAPABILITY = {
        "name" => "note.update",
        "description" => "Change one of the household's notes: a new `title` (its first line), new plain `text` replacing " \
                         "everything after the title, `html` replacing the whole body, or a move to another `folder` of the " \
                         "same backend. Replacing text cannot be undone from hob and Notes keeps no history: read the note with " \
                         "note.get first and keep what should stay, or use note.append to add. A locked note cannot be changed. " \
                         "Returns { note: #{FULL_NOTE_SHAPE}, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "id" => NOTE,
            "title" => TITLE,
            "text" => { "type" => "string", "maxLength" => Notes::MAX_TEXT, "description" => "Replaces everything after the title, as plain text" },
            "html" => { "type" => "string", "maxLength" => Notes::MAX_TEXT, "description" => "Replaces the whole body, title included; not with title or text" },
            "folder" => FOLDER.merge("description" => "Move it here: #{FOLDER['description']}, in the note's own backend")
          },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Notes.update(arguments))
      end
    end
  end
end
