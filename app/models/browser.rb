# One real browser somewhere in the house (BROWSE.md): gofer's Chrome on
# the Mac mini, with a profile a person has logged into. Browsers are rows,
# not code; hob reaches one through the adapter the row's `kind` names
# (Browse::Backends), and every session in it is a BrowseSession.
#
# `realm` is the realm of everything seen or done in the browser: the
# profile's logins are the owner's, so the realm is theirs. Reading needs
# clearance at or above it, which RLS enforces on this table: a household
# agent cannot see a `personal` browser, so it cannot name one, so it cannot
# open a session in it.
#
# config, for kind gofer:
#   url      gofer's base URL, e.g. http://mini.tailnet.ts.net:8378
#   key_env  the env var holding gofer's bearer key, read at request time; or
#   key      the key itself, stored in the row
#   addr     optional: connect to this address (a tailnet IP) while `url`
#            keeps the hostname, as Hob::Client's ipaddr: does
#   domains  optional: where sessions may go, narrower than gofer's own key
#            allows; a session may narrow further, never widen
#
# The key never leaves: `as_json` says whether one is set and which env var
# names it, and `inspect` masks the whole config.
class Browser < ApplicationRecord
  NAME_FORMAT = TodoBackend::NAME_FORMAT

  self.filter_attributes = [ :config ]

  belongs_to :principal
  has_many :browse_sessions, dependent: :destroy

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validates :realm, presence: true
  validate :kind_known
  validate :realm_known
  validate :owned_by_a_person
  validate :config_shape

  before_validation { self.config = config.deep_stringify_keys if config.is_a?(Hash) }
  before_create { self.id ||= ULID.generate }

  scope :enabled, -> { where(enabled: true) }

  def adapter
    Browse::Backends.adapter_for(self)
  end

  def url
    config["url"].to_s.sub(%r{/+\z}, "")
  end

  def addr
    config["addr"].presence
  end

  # Where sessions in this browser may go, by the row; empty means wherever
  # the backend's own key allows.
  def domains
    Array(config["domains"]).map(&:to_s)
  end

  # The bearer key, resolved now: the row's own, or the env var it names.
  def key
    config["key"].presence || (config["key_env"].present? ? ENV[config["key_env"].to_s].presence : nil)
  end

  def realm_rank
    Realm.rank_of(realm)
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "owner" => principal&.name, "realm" => realm,
      "enabled" => enabled, "config" => safe_config, "created_at" => created_at, "updated_at" => updated_at }
  end

  def safe_config
    config.except("key").tap { |shown| shown["key"] = "set" if config["key"].present? }
  end

  private

  def kind_known
    return if Browse::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a browser kind (#{Browse::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a browser's profile holds somebody's logins") if principal && !principal.trusted?
  end

  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Browse::Backends.kind?(kind)

    Browse::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end
end
