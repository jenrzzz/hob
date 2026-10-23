# Where People::Sync is in one source's stream (text:<backend name>): the
# cursor Texts.poll last handed back, when it last ran, and what went wrong
# last if anything did. `realm` is the backend's.
class PeopleCursor < ApplicationRecord
  before_create { self.id ||= ULID.generate }
end
