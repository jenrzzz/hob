# One place a budget is kept (BUDGET.md). Backends are rows, not code: the
# accounts and transactions stay where they are (YNAB) and hob reaches them
# through the adapter the row's `kind` names (Budgets::Backends).
#
# `realm` is the realm of everything in the backend, as it is for a
# TodoBackend. Reading needs clearance at or above it, which RLS enforces on
# this table: a household agent cannot see a `personal` budget, so it cannot
# name one, so it cannot reach a transaction in it. It is also the sink
# realm of any write; nothing checks that yet (DESIGN.md's IFC gate).
#
# config, for kind ynab:
#   plan       the YNAB plan (what YNAB used to call a budget): its id, from
#              `hob:budget:plans` or the app's URL
#   key_env    the env var holding a YNAB personal access token, read at
#              request time the way providers read theirs; or
#   key        the token itself, stored in the row
#   time_zone  optional: whose "today" a transaction entered without a date
#              gets (YNAB refuses tomorrow's); default UTC
#
# The token never leaves: `as_json` says whether one is set and which env
# var names it, and `inspect` masks the whole config.
class BudgetBackend < ApplicationRecord
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

  # The adapter that speaks to wherever this budget is kept.
  def adapter
    Budgets::Backends.adapter_for(self)
  end

  # The bearer token, resolved now: the row's own, or the env var it names.
  def key
    config["key"].presence || (config["key_env"].present? ? ENV[config["key_env"].to_s].presence : nil)
  end

  # The zone a bare "today" is reckoned in.
  def time_zone
    ActiveSupport::TimeZone[config["time_zone"].to_s] || ActiveSupport::TimeZone["UTC"]
  end

  def as_json(*)
    { "id" => id, "name" => name, "kind" => kind, "owner" => principal&.name, "realm" => realm,
      "enabled" => enabled, "config" => safe_config, "created_at" => created_at, "updated_at" => updated_at }
  end

  # config as it may be shown: everything but the key, which is "set" or absent.
  def safe_config
    config.except("key").tap { |shown| shown["key"] = "set" if config["key"].present? }
  end

  private

  def kind_known
    return if Budgets::Backends.kind?(kind)

    errors.add(:kind, "#{kind.inspect} is not a budget backend kind (#{Budgets::Backends.kinds.join(', ')})")
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a budget backend holds somebody's money") if principal && !principal.trusted?
  end

  def config_shape
    return errors.add(:config, "must be an object") unless config.is_a?(Hash)
    return unless Budgets::Backends.kind?(kind)

    Budgets::Backends.adapter_class(kind).config_errors(config).each { |message| errors.add(:config, message) }
  end
end
