# One place calendars are kept (CALENDARS.md). Backends are rows, not code:
# the events stay where they are (Fastmail, a published .ics feed) and hob
# reaches them through the adapter the row's `kind` names
# (Calendars::Backends).
#
# `realm` is the realm of everything in the backend, as it is for a
# TodoBackend. Reading needs clearance at or above it, which RLS enforces on
# this table: a household agent cannot see a `personal` calendar, so it
# cannot name one, so it cannot read an event in it.
#
# config, for every kind:
#   time_zone   optional: the IANA zone a floating time (one with no zone of
#               its own) is read in; default HOB_TIME_ZONE, else UTC
#   visibility  optional: "details" (the default) or "free_busy", which
#               hands out when and whether busy, and never what or where
#
# for kind ics:
#   url         the feed's address (http, https, or webcal); or
#   url_env     the env var holding it. A private feed's URL is its
#               password, so it is treated like one
#   name        optional: what to call the calendar, over the feed's own name
#
# for kind fastmail (and caldav, which also needs a `url`):
#   username    the account's login, e.g. jenner@fastmail.com
#   key_env     the env var holding an app password, read at request time
#               the way providers read theirs; or
#   key         the app password itself, stored in the row
#   calendars   optional: the calendars (names or ids) this row may reach;
#               every other calendar on the account does not exist for it
#   url         caldav: the account's calendar home; fastmail derives it
#
# Secrets never leave: `as_json` says whether one is set and which env var
# names it, a feed URL is shown as its host alone, and `inspect` masks the
# whole config.
class CalendarBackend < ApplicationRecord
  NAME_FORMAT = TodoBackend::NAME_FORMAT

  self.filter_attributes = [ :config ]

  belongs_to :principal

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validates :realm, presence: true
  validate :kind_known
  validate :realm_known
  validate :owned_by_a_person
  validate :config_shape

  before_validation { self.config = config.deep_stringify_keys if config.is_a?(Hash) }
  before_create { self.id ||= ULID.generate }

  scope :enabled, -> { where(enabled: true) }

  # The adapter that speaks to wherever these calendars are kept.
  def adapter
    Calendars::Backends.adapter_for(self)
  end

  # A secret, resolved now: the row's own `name`, or the env var `name_env` names.
  def secret(name)
    config[name].presence || (config["#{name}_env"].present? ? ENV[config["#{name}_env"].to_s].presence : nil)
  end

  def key
    secret("key")
  end

  # Where a floating time is read, and what a bare date's midnight means.
  def time_zone
    ActiveSupport::TimeZone[config["time_zone"].to_s] || Calendars.zone
  end

  def free_busy?
    config["visibility"] == "free_busy"
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "owner" => principal&.name, "realm" => realm,
      "enabled" => enabled, "config" => safe_config, "created_at" => created_at, "updated_at" => updated_at }
  end

  # config as it may be shown: no key, and a feed URL as its host alone
  # (the rest of it is often the password).
  def safe_config
    shown = config.except("key")
    shown["key"] = "set" if config["key"].present?
    shown["url"] = Calendars::Backends::Base.redact(config["url"]) if kind == "ics" && config["url"].present?
    shown
  end

  private

  def kind_known
    return if Calendars::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a calendar backend kind (#{Calendars::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a calendar backend holds somebody's calendar") if principal && !principal.trusted?
  end

  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Calendars::Backends.kind?(kind)

    Calendars::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end
end
