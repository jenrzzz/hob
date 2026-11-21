# One Claude Code session file of one mission (SENTINEL.md, "Trajectories"),
# kept gzipped. Trajectories stores and reads them.
class MissionTrajectory < ApplicationRecord
  belongs_to :mission

  validates :session, :path, :realm, presence: true

  before_create { self.id ||= ULID.generate }

  scope :in_order, -> { order(:created_at, :path) }

  # A subagent's file, or anything else that is not the session itself.
  def side?
    path != "#{session}.jsonl"
  end

  def jsonl
    Zlib::GzipReader.new(StringIO.new(body)).read.force_encoding(Encoding::UTF_8)
  end
end
