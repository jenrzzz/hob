module Sentinel
  module Native
    # What the note.* handlers share (NOTES.md). They are thin: Notes does the
    # work, at the agent's clearance, so the libraries an agent can reach are
    # the ones RLS shows it and the handlers add no realm logic of their own.
    # Everything handed back carries Notes::NOTICE, since a shared note is
    # written by everyone it is shared with. What Notes raises (NotFound,
    # Invalid, Forbidden, Unavailable) fails the request with its message.
    class NoteHandler < Base
      BACKEND = { "type" => "string", "description" => "Only this backend (a name from a note's or folder's `backend`)" }.freeze
      NOTE = { "type" => "string", "description" => "A note id as note.search returns it: \"<backend>:<id>\"" }.freeze
      FOLDER = { "type" => "string", "description" => "A folder id as note.folders returns it: \"<backend>:<id>\"" }.freeze
      TIME = "A date (2026-11-14: midnight where the household is) or a time with its offset (2026-11-14T15:00:00-08:00)".freeze
      FOLDER_SHAPE = "{ id, backend, name, path, account, parent_id, shared, note_count, folder_count }".freeze
      NOTE_SHAPE = "{ id, backend, title, folder: { id, name, path }, account, created, modified, locked, shared, snippet?, tags? }".freeze
      FULL_NOTE_SHAPE = "{ id, backend, title, folder: { id, name, path, deleted? }, account, created, modified, locked, shared, snippet, " \
                        "tags, text, html, attachments: [{ name, content_type }] }".freeze
      TITLE = { "type" => "string", "maxLength" => Notes::MAX_TITLE, "description" => "The note's first line, which Notes shows as its title" }.freeze

      private

      def noticed(result)
        result.merge("notice" => Notes::NOTICE)
      end
    end
  end
end
