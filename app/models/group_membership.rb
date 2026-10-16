# A person in a PeopleGroup. `realm` is the higher of the two, for RLS: a
# membership is visible only where both ends of it are.
class GroupMembership < ApplicationRecord
  belongs_to :group, class_name: "PeopleGroup"
  belongs_to :person

  before_create { self.id ||= ULID.generate }
end
