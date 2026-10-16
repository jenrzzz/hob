# Someone the household knows (PEOPLE.md): the names they go by, the handles
# that reach them, the groups they are in, and the dates that come round.
# What passed between them and the household is PeopleEvent; what is still
# open is PeopleLoop; what agents and people think is PeopleNote.
#
# `realm` is who may know this person exists, and RLS enforces it here and on
# their handles and memberships. A person merged into another (People.merge)
# is not deleted: it points at the one it became, and reads of that one
# gather both, so the log stays as it was written.
class Person < ApplicationRecord
  DISPLAY_NAME_LIMIT = 200
  NAMES_LIMIT = 20
  KEY_DATES_LIMIT = 20
  KEY_DATE_KINDS = %w[birthday anniversary memorial other].freeze
  # A full date, or a month and day when the year is not known (vCard's --MM-DD).
  KEY_DATE = /\A(\d{4}|-)-(\d{2})-(\d{2})\z/

  belongs_to :principal, optional: true
  belongs_to :created_by, class_name: "Principal", optional: true
  belongs_to :merged_into, class_name: "Person", optional: true
  has_many :handles, class_name: "PersonHandle", dependent: :restrict_with_exception
  has_many :memberships, class_name: "GroupMembership", dependent: :restrict_with_exception
  has_many :groups, through: :memberships

  validates :display_name, presence: true, length: { maximum: DISPLAY_NAME_LIMIT }
  validates :realm, presence: true
  validates :cadence_days, numericality: { only_integer: true, in: 1..3650 }, allow_nil: true
  validate :realm_known
  validate :key_dates_shaped
  validate :names_shaped

  before_create { self.id ||= ULID.generate }

  scope :live, -> { where(merged_into_id: nil) }

  def merged?
    merged_into_id.present?
  end

  def ref
    "person:#{id}"
  end

  # This person's id and every id merged into it, however long the chain.
  def identity_ids
    ids = [ id ]
    frontier = [ id ]
    while frontier.any?
      frontier = Person.where(merged_into_id: frontier).pluck(:id) - ids
      ids.concat(frontier)
    end
    ids
  end

  # The next time each recurring key date comes round, from `today`:
  # [{ kind, date, next, in_days }], soonest first. A date that does not
  # recur is shown only while it is still ahead.
  def upcoming_dates(today = Date.current)
    key_dates.filter_map do |entry|
      _, year, month, day = entry["date"].to_s.match(KEY_DATE).to_a
      next unless month

      upcoming = if entry["recurs"] == false
        year == "-" ? nil : Date.new(year.to_i, month.to_i, day.to_i)
      else
        recurrence(today, month.to_i, day.to_i)
      end
      next if upcoming.nil? || upcoming < today

      entry.merge("next" => upcoming.iso8601, "in_days" => (upcoming - today).to_i)
    end.sort_by { |entry| entry["in_days"] }
  end

  def as_json(*)
    { "id" => id, "ref" => ref, "display_name" => display_name, "names" => names,
      "handles" => handles.sort_by { |h| [ h.kind, h.address ] }.map(&:as_json),
      "circles" => groups.map(&:name).sort, "key_dates" => key_dates, "automated" => automated,
      "cadence_days" => cadence_days, "realm" => realm, "whose" => principal&.name,
      "created_at" => created_at&.utc&.iso8601, "updated_at" => updated_at&.utc&.iso8601 }
  end

  private

  # Feb 29 comes round on Feb 28 in other years.
  def recurrence(today, month, day)
    [ today.year, today.year + 1 ].each do |year|
      date = Date.valid_date?(year, month, day) ? Date.new(year, month, day) : Date.new(year, month, 28)
      return date if date >= today
    end
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def names_shaped
    return errors.add(:names, "must be a list of names") unless names.is_a?(Array) && names.all? { |n| n.is_a?(String) && n.present? }

    errors.add(:names, "holds at most #{NAMES_LIMIT}") if names.size > NAMES_LIMIT
  end

  def key_dates_shaped
    return errors.add(:key_dates, "must be a list of { kind, date, recurs }") unless key_dates.is_a?(Array)
    return errors.add(:key_dates, "holds at most #{KEY_DATES_LIMIT}") if key_dates.size > KEY_DATES_LIMIT

    key_dates.each_with_index do |entry, index|
      unless entry.is_a?(Hash) && (entry.keys - %w[kind date recurs label]).empty?
        next errors.add(:key_dates, "[#{index}] must be { kind, date, recurs?, label? }")
      end
      errors.add(:key_dates, "[#{index}].kind must be one of #{KEY_DATE_KINDS.join(', ')}") unless KEY_DATE_KINDS.include?(entry["kind"])
      _, year, month, day = entry["date"].to_s.match(KEY_DATE).to_a
      valid = month && (year == "-" ? Date.valid_date?(2000, month.to_i, day.to_i) : Date.valid_date?(year.to_i, month.to_i, day.to_i))
      errors.add(:key_dates, "[#{index}].date must be YYYY-MM-DD, or --MM-DD when the year is not known") unless valid
      errors.add(:key_dates, "[#{index}].recurs must be true or false") if entry.key?("recurs") && ![ true, false ].include?(entry["recurs"])
      errors.add(:key_dates, "[#{index}]: a date without a year must recur") if year == "-" && entry["recurs"] == false
    end
  end
end
