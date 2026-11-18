# Multimodal content on the way in (MEMORY.md, "Images"): a message's or a
# tool result's `content` may be a string, or a list of blocks
#
#   [{ type: "text", text }, { type: "image", media_type, data: <base64> },
#    { type: "image", digest: "sha256:..." }]          (an image hob already holds)
#
# Images are stored once per realm in Blob and the node keeps only
# { type, media_type, digest, size }, so content-addressed nodes and prompt
# snapshots stay small and a re-sent image costs nothing.
module Attachments
  MAX_PER_MESSAGE = 20

  module_function

  # -> [text, attachments]
  def ingest(content, realm:)
    return [ content.to_s, [] ] if content.nil? || content.is_a?(String)
    return [ JSON.generate(content), [] ] if content.is_a?(Hash) && !block?(content)

    blocks = content.is_a?(Hash) ? [ content ] : Array(content)
    return [ JSON.generate(content), [] ] unless blocks.all? { |b| block?(b) }

    texts = []
    attachments = []
    blocks.each do |raw|
      b = raw.to_h.stringify_keys
      case b["type"]
      when "text" then texts << b["text"].to_s
      when "image" then attachments << image(b, realm: realm)
      end
    end
    raise Gateway::Invalid, "at most #{MAX_PER_MESSAGE} images per message" if attachments.size > MAX_PER_MESSAGE

    [ texts.join("\n\n"), attachments ]
  end

  def block?(value)
    value.respond_to?(:to_h) && %w[text image].include?(value.to_h.stringify_keys["type"].to_s)
  end

  def image(block, realm:)
    if block["digest"].present? && block["data"].blank?
      # Only a copy at or below the node's realm may be pointed at: a node
      # naming bytes its own readers cannot see would leak that they exist,
      # and copying them down would be declassification.
      rank = Realm.rank_of(realm)
      blob = Blob.where(digest: block["digest"]).to_a.find { |b| Realm.rank_of(b.realm) <= rank }
      raise Gateway::Invalid, "no image #{block['digest']} at #{realm} or below; send its data" if blob.nil?
    else
      media_type = block["media_type"].to_s
      bytes = begin
        Base64.strict_decode64(block["data"].to_s)
      rescue ArgumentError
        raise Gateway::Invalid, "image data must be base64"
      end
      blob = Blob.store!(bytes: bytes, media_type: media_type, realm: realm)
    end
    { "type" => "image", "media_type" => blob.media_type, "digest" => blob.digest, "size" => blob.size }
  end
end
