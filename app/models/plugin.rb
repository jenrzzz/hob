# A plugin installation (PLUGINS.md, sections 4 and 6): one app, at one
# address, offering capabilities under one namespace. The plugin type is
# what the app is (its manifest's `surface`); the installation is this
# household's copy of it, with its own principal, namespace, and
# (optionally) owner.
#
#   principal  a `surface` principal hob mints at registration. It decides
#              nothing and holds no rules; quarantining the installation
#              freezes it, and every capability the installation offers is
#              then refused, whoever asks (Capability#unavailable_to).
#   namespace  every capability name it offers starts with "<namespace>.".
#              Set at registration and never changed: another installation
#              cannot take its rows, and it cannot take another's.
#   owner      the person a personal installation belongs to (Jenner's
#              address book, say). Higher clearance never grants another
#              person's data, and until hob has a model for an agent acting
#              on a person's behalf, a personal installation is not offered
#              to agents at all: only its owner reaches it.
#   key        hob-minted, handed to the plugin as HOB_PLUGIN_KEY: it signs
#              the plugin's manifest and its announcements (PluginSignature).
#              Once a signed manifest has verified (signed_since), an
#              unsigned one is refused, and the plugin may ask hob to
#              refresh it (POST /v1/plugins/announce). One that has never
#              signed keeps the trust it had: its HTTPS origin, refreshed
#              only by a person.
class Plugin < ApplicationRecord
  NAMESPACE_FORMAT = /\A[a-z0-9]+(?:[_-][a-z0-9]+)*\z/
  PRINCIPAL_PREFIX = "plugin:".freeze

  belongs_to :principal
  belongs_to :owner, class_name: "Principal", optional: true
  has_many :capabilities, dependent: :restrict_with_exception

  attr_readonly :namespace

  validates :namespace, presence: true, uniqueness: true, format: { with: NAMESPACE_FORMAT }
  validates :plugin_type, presence: true, format: { with: NAMESPACE_FORMAT }
  validates :base_url, presence: true, format: { with: %r{\Ahttps?://\S+\z} }
  validate :principal_is_a_surface
  validate :owner_is_a_person

  # A new installation and the principal it acts as.
  def self.install!(namespace:, plugin_type:, base_url:, owner: nil)
    transaction do
      principal = Principal.create!(kind: "surface", name: "#{PRINCIPAL_PREFIX}#{namespace}", max_clearance: Realm.order(:rank).first.slug)
      create!(namespace: namespace, plugin_type: plugin_type, base_url: base_url, owner: owner, principal: principal)
    end
  end

  # Whether it has proven it signs its manifest: the condition for it to
  # refresh itself, with no person running the command.
  def signed?
    signed_since.present?
  end

  # The keys a signature from it may be made with: the current one, and,
  # until a manifest signed with the current one arrives, the one before it.
  def accepted_keys
    [ key, (previous_key unless key_confirmed_at) ].compact_blank
  end

  # A new key, minted by hob. The one that last worked keeps verifying until
  # the plugin proves it holds the new one, so a failed cutover loses
  # nothing. Before any signed manifest has confirmed a key, the plugin may
  # already be using the current one, so it is kept unless an earlier one
  # is still standing in for it.
  def rekey!(new_key)
    working = key_confirmed_at ? key : (previous_key.presence || key)
    update!(key: new_key, previous_key: working, key_confirmed_at: nil)
  end

  # A signed manifest verified with `with` (one of accepted_keys).
  def manifest_verified!(with:, revision:, digest:)
    attrs = { manifest_revision: revision, manifest_digest: digest, refreshed_at: Time.current }
    attrs[:signed_since] = Time.current unless signed?
    attrs.merge!(key_confirmed_at: Time.current, previous_key: nil) if with == key && key_confirmed_at.nil?
    update!(attrs)
  end

  def personal?
    owner_id.present?
  end

  def quarantined?
    principal.capabilities_frozen?
  end

  # One switch: every capability it offers is refused, whoever asks, until
  # a person releases it. Its rows are left as they are.
  def quarantine!(reason:)
    principal.freeze_capabilities!(reason: reason)
  end

  def release!
    principal.unfreeze_capabilities!
  end

  # -> why `caller` may not reach this installation's capabilities, or nil.
  def unavailable_to(caller)
    return "#{namespace} is quarantined: #{principal.capabilities_freeze_reason}" if quarantined?
    return nil unless personal?
    return "#{namespace} is #{owner.name}'s; no agent may act for a person yet" if caller.nil? || caller.agent?
    return "#{namespace} is #{owner.name}'s, not #{caller.name}'s" unless caller.id == owner_id

    nil
  end

  private

  def principal_is_a_surface
    errors.add(:principal, "must be a surface principal") if principal && principal.kind != "surface"
  end

  def owner_is_a_person
    errors.add(:owner, "must be a person") if owner && !owner.trusted?
  end
end
