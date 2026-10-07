# One Messages account (TEXTS.md). Backends are rows, not code: the messages
# stay where they are (the Messages app on the Mac mini, behind herald) and
# hob reaches them through the adapter the row's `kind` names
# (Texts::Backends).
#
# `realm` is the realm of everything in the backend, as it is for a
# MailBackend. Reaching it needs clearance at or above it, which RLS
# enforces on this table: a household agent cannot see a `personal` account,
# so it cannot name one, so it cannot read a chat in it or send to one.
#
# config, for kind herald:
#   url        herald's base URL, e.g. http://mini.tailnet.ts.net:8379
#   key_env    the env var holding herald's bearer key, read at request time;
#              or
#   key        the key itself, stored in the row
#   addr       optional: connect to this address (a tailnet IP) while `url`
#              keeps the hostname, as TodoBackend's does
#   read_only  optional: true refuses every send, whatever herald's key could do
#
# The key never leaves: `as_json` says whether one is set and which env var
# names it, and `inspect` masks the whole config.
class TextBackend < ApplicationRecord
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

  # The adapter that speaks to wherever these messages are kept.
  def adapter
    Texts::Backends.adapter_for(self)
  end

  def url
    config["url"].to_s.sub(%r{/+\z}, "")
  end

  def addr
    config["addr"].presence
  end

  # The bearer key, resolved now: the row's own, or the env var key_env names.
  def key
    config["key"].presence || (config["key_env"].present? ? ENV[config["key_env"].to_s].presence : nil)
  end

  def read_only?
    config["read_only"] == true
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "owner" => principal&.name, "realm" => realm,
      "enabled" => enabled, "config" => safe_config, "created_at" => created_at, "updated_at" => updated_at }
  end

  # config as it may be shown: everything but the key, which is "set" or absent.
  def safe_config
    shown = config.except("key")
    shown["key"] = "set" if config["key"].present?
    shown
  end

  private

  def kind_known
    return if Texts::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a text backend kind (#{Texts::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a text backend holds somebody's messages") if principal && !principal.trusted?
  end

  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Texts::Backends.kind?(kind)

    Texts::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end
end
