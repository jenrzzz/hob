# One mail account (MAIL.md). Backends are rows, not code: the mail stays
# where it is (Fastmail) and hob reaches it through the adapter the row's
# `kind` names (Email::Backends).
#
# `realm` is the realm of everything in the backend, as it is for a
# CalendarBackend. Reaching it needs clearance at or above it, which RLS
# enforces on this table: a household agent cannot see a `personal` account,
# so it cannot name one, so it cannot read, move, or send a message in it.
#
# config:
#   key_env     the env var holding a JMAP API token, read at request time;
#               or
#   key         the token itself, stored in the row
#   url         jmap: the server's JMAP session resource; fastmail knows its own
#   mailboxes   optional: the mailboxes (names, paths, roles, or ids) this row
#               may reach, with everything under them; every other mailbox
#               on the account, and every message only in one, does not
#               exist for it
#   read_only   optional: true refuses every move, new mailbox, send, and
#               reply, whatever the token could do
#
# Secrets never leave: `as_json` says whether a key is set and which env var
# names it, and `inspect` masks the whole config.
class MailBackend < ApplicationRecord
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

  # The adapter that speaks to wherever this mail is kept.
  def adapter
    Email::Backends.adapter_for(self)
  end

  # The token, resolved now: the row's own, or the env var key_env names.
  def key
    config["key"].presence || (config["key_env"].present? ? ENV[config["key_env"].to_s].presence : nil)
  end

  def read_only?
    config["read_only"] == true
  end

  def confined?
    config["mailboxes"].present?
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "owner" => principal&.name, "realm" => realm,
      "enabled" => enabled, "config" => safe_config, "created_at" => created_at, "updated_at" => updated_at }
  end

  def safe_config
    shown = config.except("key")
    shown["key"] = "set" if config["key"].present?
    shown
  end

  private

  def kind_known
    return if Email::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a mail backend kind (#{Email::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a mail backend holds somebody's mail") if principal && !principal.trusted?
  end

  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Email::Backends.kind?(kind)

    Email::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end
end
