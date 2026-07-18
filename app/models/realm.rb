class Realm < ApplicationRecord
  self.primary_key = :slug

  validates :slug, :rank, presence: true

  def self.rank_of(slug)
    @ranks ||= Realm.pluck(:slug, :rank).to_h
    @ranks.fetch(slug) { raise ArgumentError, "unknown realm #{slug.inspect}" }
  end

  def self.reset_cache!
    @ranks = nil
  end
end
