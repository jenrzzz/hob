module Sentinel
  module Native
    # note.search: notes by folder, words, hashtag, or when they changed.
    class NoteSearch < NoteHandler
      CAPABILITY = {
        "name" => "note.search",
        "description" => "Find the household's notes visible at the agent's clearance, the most recently modified first: in a " \
                         "`folder` (and the folders inside it), with words `q` in the title or text, carrying a hashtag `tag`, " \
                         "or modified in a window. Every filter given must match. #{Notes::DEFAULT_LIMIT} by default and at most " \
                         "#{Notes::MAX_LIMIT}; `truncated` means there were more: narrow the search, or page back with " \
                         "modified_before set to the last note's modified. `snippet` and `tags` come with a q or tag search, or " \
                         "when asked for with snippet: true (slower: every note's text is read). Read a whole note with note.get. " \
                         "Returns { notes: [#{NOTE_SHAPE}], count, truncated, unavailable, notice }. Times carry the household's offset.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "folder" => FOLDER.merge("description" => "Only notes in this folder or one inside it: #{FOLDER['description']}"),
            "q" => { "type" => "string", "description" => "Words that must all appear in the title or text" },
            "tag" => { "oneOf" => [ { "type" => "string" }, { "type" => "array", "items" => { "type" => "string" } } ],
                       "description" => "A hashtag (breakfast or #breakfast), or a list that must all be on the note" },
            "modified_after" => { "type" => "string", "description" => "Modified at or after: #{TIME}" },
            "modified_before" => { "type" => "string", "description" => "Modified before: #{TIME}" },
            "snippet" => { "type" => "boolean", "default" => false, "description" => "true: each note's opening text and tags, even without q or tag" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Notes::MAX_LIMIT, "default" => Notes::DEFAULT_LIMIT }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Notes.search(arguments)
        noticed(result.merge("count" => result["notes"].size))
      end
    end
  end
end
