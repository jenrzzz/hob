# Casts (CASTS.md): shows hob produces from what a surface hands it, the
# episodes of each, and the audio hob has paid a voice provider for, kept
# by what was asked so the same line is never bought twice.
class CreateCasts < ActiveRecord::Migration[8.1]
  ROLES = {
    "cast-writer" => [ { "provider" => "anthropic", "model" => "claude-opus-5-5",
                         "params" => { "max_tokens" => 16_384 } },
                       { "provider" => "anthropic", "model" => "claude-sonnet-5-5",
                         "params" => { "max_tokens" => 16_384 } } ],
    "voice-dialogue" => [ { "provider" => "elevenlabs", "model" => "eleven_v4" } ],
    "voice-sound" => [ { "provider" => "elevenlabs", "model" => "eleven_text_to_sound_v2" } ],
    "voice-music" => [ { "provider" => "elevenlabs", "model" => "music_v1" } ]
  }.freeze

  def up
    create_table :casts, id: :string do |t|
      t.string :slug, null: false
      t.string :title, null: false
      t.text :description
      t.string :realm, null: false
      t.string :token, null: false
      t.jsonb :config, null: false, default: {}
      t.timestamps

      t.index :slug, unique: true
      t.index :token, unique: true
    end

    create_table :cast_episodes, id: :string do |t|
      t.references :cast, type: :string, null: false, foreign_key: true, index: false
      t.string :edition, null: false
      t.string :title, null: false
      t.text :summary
      t.string :status, null: false, default: "queued"
      t.text :error
      t.string :realm, null: false
      t.string :surface
      t.jsonb :source, null: false, default: {}
      t.jsonb :script, null: false, default: {}
      t.jsonb :production, null: false, default: {}
      t.string :audio_key
      t.integer :audio_size
      t.integer :duration_ms
      t.datetime :published_at
      t.timestamps

      t.index [ :cast_id, :edition ], unique: true
      t.index [ :cast_id, :published_at ]
    end

    # Keyed by (realm, key) as blobs are, so the same clip at two realms is
    # two rows and an insert never collides with a row RLS hides.
    create_table :audio_clips, primary_key: %i[realm key] do |t|
      t.string :realm, null: false
      t.string :key, null: false
      t.string :kind, null: false
      t.string :media_type, null: false, default: "audio/mpeg"
      t.binary :bytes, null: false
      t.integer :size, null: false
      t.jsonb :meta, null: false, default: {}
      t.datetime :created_at, null: false

      t.index [ :kind, :created_at ]
    end

    %w[casts cast_episodes audio_clips].each do |table|
      execute <<~SQL
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
        CREATE POLICY realm_visibility ON #{table}
          USING ((SELECT rank FROM realms WHERE slug = #{table}.realm) <= app_clearance_rank());
      SQL
    end

    # Existing installations never run seeds again: give them the voice
    # provider and the roles a cast is made with. New installs get the same
    # rows from seeds.
    now = connection.quote(Time.current)
    execute <<~SQL
      INSERT INTO providers (slug, kind, config, created_at, updated_at)
      VALUES ('elevenlabs', 'elevenlabs', '{"api_key_env":"ELEVENLABS_API_KEY"}', #{now}, #{now})
      ON CONFLICT (slug) DO NOTHING
    SQL
    ROLES.each do |role, chain|
      execute <<~SQL
        INSERT INTO model_roles (role, chain, created_at, updated_at)
        VALUES (#{connection.quote(role)}, #{connection.quote(chain.to_json)}, #{now}, #{now})
        ON CONFLICT (role) DO NOTHING
      SQL
    end
  end

  def down
    %w[audio_clips cast_episodes casts].each do |table|
      execute "DROP POLICY IF EXISTS realm_visibility ON #{table}"
      drop_table table
    end
  end
end
