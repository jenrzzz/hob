module Sentinel
  module Native
    # note.create: a new note in the household's Notes. It stays inside the
    # household, as a todo does, so it is an act a policy may allow outright.
    class NoteCreate < NoteHandler
      CAPABILITY = {
        "name" => "note.create",
        "description" => "Write a new note in the household's Notes: a `title` (its first line) and plain `text` after it, " \
                         "into a `folder` from note.folders, or the backend's default folder when none is given. `html` " \
                         "instead gives the whole body, title included. It syncs to everyone's devices like any note. " \
                         "Returns { note: #{FULL_NOTE_SHAPE}, notice }. A create that fails as unavailable may still have " \
                         "happened: look with note.search before trying again.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "folder" => FOLDER.merge("description" => "Where it goes: #{FOLDER['description']}"),
            "backend" => { "type" => "string", "description" => "Which library, when giving no folder and more than one is visible" },
            "title" => TITLE,
            "text" => { "type" => "string", "maxLength" => Notes::MAX_TEXT, "description" => "Plain text after the title; each line a line in the note" },
            "html" => { "type" => "string", "maxLength" => Notes::MAX_TEXT, "description" => "Instead of title and text: the whole body as HTML" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Notes.create(arguments))
      end
    end
  end
end
