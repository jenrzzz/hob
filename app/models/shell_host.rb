# One login on one machine an agent may run commands on (SHELL.md). Hosts
# are rows, not code; hob reaches one through the adapter the row's `kind`
# names (Shells::Backends), a command at a time.
#
# `realm` is the realm of what is on the machine. Reaching it needs
# clearance at or above it, which RLS enforces on this table: an agent below
# it cannot see the host, so it cannot name it, so it cannot run anything
# there.
#
# `agent`, optional, makes the row one agent's own machine: only that agent,
# and people, reach it, and that agent reaches no other host. Shells.hosts
# enforces it, beside RLS, as Notes.backends does for a library.
#
# config, for kind ssh:
#   host      a hostname or an address
#   port      optional, default 22
#   user      the login
#   key_env   the env var holding hob's private key for this login, read at
#             request time; or
#   key       the private key itself, stored in the row
#   host_key  the machine's own key as hob first saw it, "ssh-ed25519
#             SHA256:...": set by `hob:shell:trust`, and a host without one
#             is not connected to
#
# A private key may be the OpenSSH text or that text in base64 (one line,
# for an env var). It never leaves: `as_json` says whether one is set and
# which env var names it, and `inspect` masks the whole config.
class ShellHost < ApplicationRecord
  NAME_FORMAT = TodoBackend::NAME_FORMAT

  self.filter_attributes = [ :config ]

  belongs_to :principal
  belongs_to :agent, class_name: "Principal", optional: true

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validates :realm, presence: true
  validates :about, length: { maximum: 500 }
  validate :kind_known
  validate :realm_known
  validate :owned_by_a_person
  validate :kept_for_an_agent
  validate :config_shape

  before_validation { self.config = config.deep_stringify_keys if config.is_a?(Hash) }
  before_create { self.id ||= ULID.generate }

  scope :enabled, -> { where(enabled: true) }

  def adapter
    Shells::Backends.adapter_for(self)
  end

  def address
    config["host"].to_s
  end

  def port
    (config["port"].presence || 22).to_i
  end

  def user
    config["user"].to_s
  end

  # "user@host", with the port when it is not 22.
  def login
    "#{user}@#{address}#{port == 22 ? '' : ":#{port}"}"
  end

  # The private key, resolved now: the row's own, or the env var it names.
  # Base64 of the key (how a multi-line key survives an env var) is decoded.
  def key
    raw = config["key"].presence || (config["key_env"].present? ? ENV[config["key_env"].to_s].presence : nil)
    return nil if raw.blank?
    return raw.gsub("\\n", "\n") if raw.include?("-----BEGIN")

    decoded = Base64.decode64(raw)
    decoded.include?("-----BEGIN") ? decoded : raw
  end

  # The machine's key as pinned, "type SHA256:..." (or the fingerprint alone).
  def host_key
    config["host_key"].presence
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "about" => about, "owner" => principal&.name, "agent" => agent&.name,
      "realm" => realm, "enabled" => enabled, "config" => safe_config, "created_at" => created_at, "updated_at" => updated_at }
  end

  def safe_config
    config.except("key").tap { |shown| shown["key"] = "set" if config["key"].present? }
  end

  private

  def kind_known
    return if Shells::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a shell host kind (#{Shells::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: somebody answers for a machine") if principal && !principal.trusted?
  end

  def kept_for_an_agent
    errors.add(:agent, "must be an agent: #{agent.name} is a #{agent.kind}") if agent && !agent.agent?
  end

  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Shells::Backends.kind?(kind)

    Shells::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end
end
