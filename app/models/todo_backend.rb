# One place todos live (TODOS.md). Backends are rows, not code: the todos
# themselves stay where they are (OmniFocus, behind tally) and hob reaches
# them through the adapter the row's `kind` names (Todos::Backends).
#
# `realm` is the realm of everything in the backend. Reading needs clearance
# at or above it, which RLS enforces on this table: a household agent cannot
# see a `personal` backend, so it cannot name one, so it cannot reach a todo
# in it. It is also the *sink realm* of any write, the annotation the IFC
# gate (DESIGN.md) will compare against a conversation's taint when it
# exists; nothing checks it yet.
#
# config, for kind omnifocus:
#   url      tally's base URL, e.g. http://mini.tailnet.ts.net:8377
#   key_env  the env var holding tally's bearer key, read at request time
#            the way providers read theirs; or
#   key      the key itself, stored in the row
#   addr     optional: connect to this address (a tailnet IP) while `url`
#            keeps the hostname, as Hob::Client's ipaddr: does
#   create_tags  optional: true lets a write make tags OmniFocus does not have yet
#
# The key never leaves: `as_json` says whether one is set and which env var
# names it, and `inspect` masks the whole config.
class TodoBackend < ApplicationRecord
  NAME_FORMAT = /\A[a-z0-9]+(?:[._-][a-z0-9]+)*\z/

  # Masks config in `inspect`, and the wrapped `todo_backend[config]` copy in request logs.
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
  # One default per owner: a new primary takes the title from the old one.
  after_save :demote_other_primaries, if: -> { primary? && (saved_change_to_primary? || saved_change_to_principal_id?) }

  scope :enabled, -> { where(enabled: true) }

  # The adapter that speaks to wherever these todos live.
  def adapter
    Todos::Backends.adapter_for(self)
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

  def realm_rank
    Realm.rank_of(realm)
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "owner" => principal&.name, "realm" => realm,
      "enabled" => enabled, "primary" => primary, "config" => safe_config,
      "created_at" => created_at, "updated_at" => updated_at }
  end

  # config as it may be shown: everything but the key, which is "set" or absent.
  def safe_config
    config.except("key").tap { |shown| shown["key"] = "set" if config["key"].present? }
  end

  private

  def kind_known
    return if Todos::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a todo backend kind (#{Todos::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a todo backend holds somebody's todos") if principal && !principal.trusted?
  end

  # What a config must hold is the adapter's business: tally wants a url
  # and a key; a backend living in hob's own tables would want neither.
  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Todos::Backends.kind?(kind)

    Todos::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end

  def demote_other_primaries
    TodoBackend.where(principal_id: principal_id, primary: true).where.not(id: id).update_all(primary: false, updated_at: Time.current)
  end
end
