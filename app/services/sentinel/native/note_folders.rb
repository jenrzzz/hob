module Sentinel
  module Native
    # note.folders: where the household's notes are filed.
    class NoteFolders < NoteHandler
      CAPABILITY = {
        "name" => "note.folders",
        "description" => "The folders of the household's notes (the Notes app, by way of hob) visible at the agent's clearance, " \
                         "by backend and path. A folder's id is what note.search takes as `folder` and note.create and " \
                         "note.update take as where a note goes. Returns { folders: [#{FOLDER_SHAPE}], count, unavailable: " \
                         "[{ backend, error }], notice }. `note_count` counts notes directly in the folder.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "q" => { "type" => "string", "description" => "Words in the folder's path, like recipes" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Notes.folders(arguments)
        noticed(result.merge("count" => result["folders"].size))
      end
    end
  end
end
