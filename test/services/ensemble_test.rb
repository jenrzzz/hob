require "test_helper"

class EnsembleTest < ActiveSupport::TestCase
  test "splits a tagged reply into speaker segments in order" do
    reply = "[saffron]\nSoup tonight.\n\n[maggie] Oh, lovely — with bread?\n[saffron]\nAlways."
    assert_equal [ [ "saffron", "Soup tonight." ], [ "maggie", "Oh, lovely — with bread?" ], [ "saffron", "Always." ] ],
                 Assembly::Ensemble.split(reply, %w[saffron maggie])
  end

  test "untagged leading text belongs to the first speaker; unknown tags are text" do
    assert_equal [ [ "saffron", "Hello.\n[cook] not a speaker" ], [ "maggie", "Hi." ] ],
                 Assembly::Ensemble.split("Hello.\n[cook] not a speaker\n[Maggie] Hi.", %w[saffron maggie])
  end

  test "a single speaker is one segment, blanks dropped" do
    assert_equal [ [ "hob", "Hi." ] ], Assembly::Ensemble.split("  Hi.  ", %w[hob])
    assert_equal [ [ nil, "Hi." ] ], Assembly::Ensemble.split("Hi.", [])
    assert_empty Assembly::Ensemble.split("[saffron]\n\n[maggie]", %w[saffron maggie])
  end
end
