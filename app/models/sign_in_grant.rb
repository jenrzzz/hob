# The companion app signing in (clients/ios): after a person confirms in the
# browser, hob hands the app a one-time code through its hob:// redirect, and
# the app trades it for a key at POST /v1/app_sessions. The code is good once,
# for TTL, and only with the verifier behind the app's PKCE challenge (RFC
# 7636, S256), so another app catching the redirect can't redeem it.
class SignInGrant < ApplicationRecord
  TTL = 2.minutes
  CHALLENGE_FORMAT = /\A[A-Za-z0-9_-]{43}\z/ # base64url(SHA-256), unpadded

  class Invalid < StandardError; end

  belongs_to :principal

  validates :code_digest, :code_challenge, :surface, :expires_at, presence: true
  validates :code_challenge, format: { with: CHALLENGE_FORMAT }

  # -> the raw code, for the redirect; only its digest is kept.
  def self.issue!(principal:, code_challenge:, surface:)
    where(expires_at: ...1.hour.ago).delete_all
    code = SecureRandom.urlsafe_base64(32)
    create!(principal: principal, code_challenge: code_challenge, surface: surface,
            code_digest: ApiKey.digest(code), expires_at: TTL.from_now)
    code
  end

  # Burn the code whatever happens, then mint the key: a new key for the
  # principal's surface, its older ones there revoked. -> [token, grant]
  def self.redeem!(code:, code_verifier:)
    grant = find_by(code_digest: ApiKey.digest(code.to_s))
    raise Invalid, "unknown code" if grant.nil?

    burned = where(id: grant.id, redeemed_at: nil).where(expires_at: Time.current..).update_all(redeemed_at: Time.current)
    raise Invalid, "code expired or already used" unless burned == 1
    raise Invalid, "code_verifier does not match" unless grant.verifies?(code_verifier)
    raise Invalid, "#{grant.principal.name} can no longer sign in" unless grant.principal.trusted?

    token, = ApiKey.rotate!(principal: grant.principal, surface: grant.surface, default_clearance: grant.principal.max_clearance)
    [ token, grant ]
  end

  def verifies?(verifier)
    return false if verifier.blank?

    ActiveSupport::SecurityUtils.secure_compare(Base64.urlsafe_encode64(Digest::SHA256.digest(verifier.to_s), padding: false), code_challenge)
  end
end
