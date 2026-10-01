require "test_helper"

# Upkeep discovery (SCHEDULES.md, "Upkeep"): Coolify's apps become two
# schedules per household repo for the forge.
class UpkeepTest < ActiveSupport::TestCase
  class FakeCoolify
    attr_accessor :apps

    def initialize(apps) = @apps = apps
    def call(method, path, _body) = (method == :get && path == "/applications" ? @apps : {})
  end

  setup do
    @forge, _ = forge!
    @coolify = FakeCoolify.new([
      { "name" => "hob", "git_repository" => "jenrzzz/hob", "git_branch" => "main" },
      { "name" => "hob-forge", "git_repository" => "https://github.com/jenrzzz/hob.git", "git_branch" => "main" },
      { "name" => "airing", "git_repository" => "git@github.com:jenrzzz/airing.git", "git_branch" => "trunk" },
      { "name" => "sillytavern", "git_repository" => "SillyTavern/SillyTavern", "git_branch" => "release" },
      { "name" => "plex", "git_repository" => nil, "docker_registry_image_name" => "plexinc/pms-docker" }
    ])
  end

  def discover(**opts)
    Upkeep.discover!(coolify: Provision::Coolify.new(transport: @coolify), **opts)
  end

  test "repo_of reads every way Coolify spells a GitHub source" do
    assert_equal "jenrzzz/hob", Upkeep.repo_of("jenrzzz/hob")
    assert_equal "jenrzzz/hob", Upkeep.repo_of("https://github.com/jenrzzz/hob.git")
    assert_equal "jenrzzz/hob", Upkeep.repo_of("git@github.com:jenrzzz/hob.git")
    assert_nil Upkeep.repo_of("https://gitlab.com/a/b")
    assert_nil Upkeep.repo_of(nil)
  end

  test "each household repo gets a weekly minor and a monthly major schedule for the forge, spread out" do
    report = discover
    assert_equal %w[jenrzzz/airing jenrzzz/hob], report.repos
    assert_equal %w[upkeep-airing upkeep-airing-major upkeep-hob upkeep-hob-major], report.created.sort
    assert_equal 4, Schedule.count

    minor = Schedule.find_by!(name: "upkeep-airing")
    assert_equal [ nil, @forge, "household", -1, "upkeep: jenrzzz/airing" ],
                 [ minor.created_by, minor.assignee, minor.realm, minor.priority, minor.title ]
    assert_equal({ "kind" => "forge.upkeep", "repo" => "jenrzzz/airing", "branch" => "trunk", "scope" => "minor" }, minor.payload)
    assert_match(/\A(0|15|30|45) [2-5] \* \* [0-6]\z/, minor.cron)
    major = Schedule.find_by!(name: "upkeep-hob-major")
    assert_equal "major", major.payload["scope"]
    assert_match(/\A(0|15|30|45) 3 ([1-9]|1\d|2[0-8]) \* \*\z/, major.cron)
    assert_in_delta 7.days, minor.interval, 1.day
  end

  test "a person's timing and switch survive rediscovery; the payload follows Coolify" do
    discover
    Schedule.find_by!(name: "upkeep-hob").update!(cron: "0 9 * * 6", enabled: false)
    @coolify.apps.first["git_branch"] = "trunk"
    @coolify.apps.delete_at(1)

    report = discover
    assert_equal [ "upkeep-hob", "upkeep-hob-major" ], report.updated.sort
    assert_empty report.created
    hob = Schedule.find_by!(name: "upkeep-hob")
    assert_equal [ "0 9 * * 6", false, "trunk" ], [ hob.cron, hob.enabled?, hob.payload["branch"] ]
    assert_empty discover.updated, "nothing changed, nothing touched"
  end

  test "a repo that leaves Coolify is disabled, not deleted; a dry run changes nothing" do
    discover
    @coolify.apps.reject! { |a| a["name"] == "airing" }
    dry = discover(dry_run: true)
    assert_equal %w[upkeep-airing upkeep-airing-major], dry.disabled.sort
    assert Schedule.find_by!(name: "upkeep-airing").enabled?

    discover
    gone = Schedule.find_by!(name: "upkeep-airing")
    refute gone.enabled?
    assert_match(/no longer on Coolify/, gone.description)
  end

  test "HOB_UPKEEP_OWNERS widens who counts as the household" do
    ENV["HOB_UPKEEP_OWNERS"] = "jenrzzz,SillyTavern"
    assert_includes discover.repos, "SillyTavern/SillyTavern"
  ensure
    ENV.delete("HOB_UPKEEP_OWNERS")
  end

  test "no forge, no discovery" do
    @forge.update!(name: "retired")
    assert_raises(ArgumentError) { discover }
  end
end
