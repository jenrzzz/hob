# Crockford-base32 ULIDs: 48-bit millisecond timestamp + 80 random bits.
# Lexicographic order == creation order, which is all hob needs from them.
module ULID
  ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".freeze

  def self.generate(time = Time.now)
    ms = (time.to_f * 1000).to_i
    chars = String.new
    10.times { chars.prepend(ENCODING[ms & 31]); ms >>= 5 }
    16.times { chars << ENCODING[SecureRandom.random_number(32)] }
    chars
  end
end
