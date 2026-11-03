# One KVM in the house (KVM.md): a screen, a keyboard, and a mouse on a
# real computer, which hob lends out a session at a time. Consoles are
# rows, not code; hob reaches one through the adapter the row's `kind`
# names (Consoles::Backends), and every session on it is a ConsoleSession.
#
# `realm` is the realm of the machine's screen: Jenner's Mac, with its
# desktop, its mail, and its password manager, is `personal`. Reading needs
# clearance at or above it, which RLS enforces on this table: an agent below
# it cannot see the console, so it cannot name it, so it cannot open a
# session on it.
#
# config, for kind jetkvm:
#   url      the bridge's base URL, e.g. http://bridgehost.tailnet.ts.net:8379
#   key_env  the env var holding the bridge's bearer key, read at request time; or
#   key      the key itself, stored in the row
#   addr     optional: connect to this address (a tailnet IP) while `url`
#            keeps the hostname
#
# The device's own password is never here: the bridge holds it. The key
# never leaves: `as_json` says whether one is set and which env var names
# it, and `inspect` masks the whole config.
class Console < ApplicationRecord
  NAME_FORMAT = TodoBackend::NAME_FORMAT

  self.filter_attributes = [ :config ]

  belongs_to :principal
  has_many :console_sessions, dependent: :destroy

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validates :realm, presence: true
  validates :machine, length: { maximum: 200 }
  validate :kind_known
  validate :realm_known
  validate :owned_by_a_person
  validate :config_shape

  before_validation { self.config = config.deep_stringify_keys if config.is_a?(Hash) }
  before_create { self.id ||= ULID.generate }

  scope :enabled, -> { where(enabled: true) }

  def adapter
    Consoles::Backends.adapter_for(self)
  end

  def url
    config["url"].to_s.sub(%r{/+\z}, "")
  end

  def addr
    config["addr"].presence
  end

  # The bearer key, resolved now: the row's own, or the env var it names.
  def key
    config["key"].presence || (config["key_env"].present? ? ENV[config["key_env"].to_s].presence : nil)
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "machine" => machine, "owner" => principal&.name, "realm" => realm,
      "enabled" => enabled, "config" => safe_config, "created_at" => created_at, "updated_at" => updated_at }
  end

  def safe_config
    config.except("key").tap { |shown| shown["key"] = "set" if config["key"].present? }
  end

  private

  def kind_known
    return if Consoles::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a console kind (#{Consoles::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a console's machine is somebody's") if principal && !principal.trusted?
  end

  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Consoles::Backends.kind?(kind)

    Consoles::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end
end
