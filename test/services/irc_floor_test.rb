require "test_helper"

# Upstairs on hob's IRC (IRC.md, "The floor" and "Invited"): an agent with a
# floor is heard only at or above it, cannot open the household channels a
# join would, and gets into a higher one by a person's invitation.
class IrcFloorTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @person = Principal.find_or_create_by!(name: "jenner") { |p| p.kind = "human"; p.max_clearance = "intimate" }
    @celestia, = agent("celestia", clearance: "intimate")
    @celestia.update!(irc_floor: "intimate")
    @luna, = agent("luna", clearance: "intimate")
    @luna.update!(irc_floor: "intimate")
    @meluzina, = agent("meluzina", clearance: "personal")
    @skipsy, = agent("skipsy")
    Clearance.with("intimate") do
      Irc.channel_by_person!("#upstairs", realm: "intimate", by: @person)
      Irc.channel_by_person!("#garden", realm: "household", by: @person)
    end
  end

  def upstairs(&) = Clearance.with("intimate", &)

  test "a floor is a realm no higher than the agent's clearance" do
    @meluzina.irc_floor = "intimate"
    refute @meluzina.valid?
    assert_match(/above meluzina's clearance/, @meluzina.errors[:irc_floor].first)

    @meluzina.irc_floor = "attic"
    refute @meluzina.valid?
    assert_match(/not a realm/, @meluzina.errors[:irc_floor].first)

    @meluzina.irc_floor = " "
    assert @meluzina.valid?
    assert_nil @meluzina.irc_floor
  end

  test "an agent with a floor cannot join, open or be heard below it" do
    error = assert_raises(Irc::Error) { upstairs { Irc.join(@celestia, "#garden") } }
    assert_match(/#garden is at household, below the intimate you keep to/, error.message)

    error = assert_raises(Irc::Error) { upstairs { Irc.join(@celestia, "#nursery") } }
    assert_match(/a channel you open is at household.*a person opens those/, error.message)
    assert_nil upstairs { IrcChannel.find_by(name: "#nursery") }, "nothing was opened"

    upstairs { Irc.join(@celestia, "#upstairs") }
    assert_equal [ "<celestia> hello" ], upstairs { Irc.say(@celestia, to: "#upstairs", body: "hello")["said"] }
      .map { |line| line.sub(/\A\[[^\]]+\] /, "") }
  end

  test "a DM that would sit below either end's floor never opens" do
    error = assert_raises(Irc::Error) { upstairs { Irc.say(@celestia, to: "meluzina", body: "hi") } }
    assert_match(/kept at personal, below the intimate you keep to/, error.message)

    @celestia.update!(accepts_lower_messages: true)
    error = assert_raises(Irc::Error) { Clearance.with("personal") { Irc.say(@meluzina, to: "celestia", body: "hi") } }
    assert_match(/below the intimate celestia keeps to/, error.message)
    assert_equal 0, upstairs { IrcChannel.dms.count }

    upstairs { Irc.say(@celestia, to: "luna", body: "psst") }
    assert_equal "intimate", upstairs { IrcChannel.dms.sole.realm }, "two upstairs agents talk upstairs"
  end

  test "the channels it may not be heard in are not offered to it" do
    upstairs do
      Irc.join(@skipsy, "#shed")
      listed = Irc.channels(@celestia)
      assert_equal "intimate", listed["floor"]
      assert_equal %w[#upstairs], listed["channels"].map { |c| c["name"] }
      assert_equal %w[#upstairs], Irc.glance(@celestia)["elsewhere"].map { |c| c["name"] }
      assert_includes Irc.channels(@skipsy)["channels"].map { |c| c["name"] }, "#shed"
    end
  end

  test "a person invites an agent in, and the room as it stood is new to it" do
    upstairs do
      Irc.join(@luna, "#upstairs")
      Irc.say(@luna, to: "#upstairs", body: "celestia: are you coming up?")

      result = Irc.invite(@person, "celestia", "#upstairs")
      assert_equal %w[celestia luna], result["members"]
      assert_equal "-- celestia joined #upstairs, invited by jenner", IrcLine.order(:id).last.to_log.sub(/\A\[[^\]]+\] /, "")

      waiting = Irc.glance(@celestia)["channels"].sole
      assert_equal 1, waiting["new"]
      assert_equal 1, waiting["naming_you"]

      assert Irc.invite(@person, "celestia", "#upstairs")["already"]
      assert_equal 1, IrcChannel.find_by!(name: "#upstairs").memberships.where(principal: @celestia).count
    end
  end

  test "an invitation keeps to clearance and floor, and is a person's" do
    upstairs do
      assert_match(/above meluzina's clearance/, assert_raises(Irc::Error) { Irc.invite(@person, "meluzina", "#upstairs") }.message)
      assert_match(/below the intimate celestia keeps to/, assert_raises(Irc::Error) { Irc.invite(@person, "celestia", "#garden") }.message)
      assert_match(/a person invites/, assert_raises(Irc::Error) { Irc.invite(@luna, "celestia", "#upstairs") }.message)
      assert_match(/nobody on IRC goes by "jenner"/, assert_raises(Irc::Error) { Irc.invite(@person, "jenner", "#upstairs") }.message)
    end
  end

  test "a beat tells a floored persona it keeps upstairs and cannot open a channel" do
    policy!(@celestia, "irc.*", "allow")
    character = persona("kat-celestia")
    character.update!(life: { "instruction" => "Live.", "realm" => "intimate" }, tools: { "agent" => "celestia" })
    page = upstairs { PersonaLife::Beat.new(PersonaLife.new(character.reload), now: Time.current, rng: Random.new(1)).prompt }
    assert_match(/You are celestia there/, page)
    assert_match(/Channels you are not in: #upstairs \(empty\)/, page)
    assert_match(/you keep to intimate channels and DMs, which a person opens/, page)
    refute_match(/#garden/, page)
  end
end
