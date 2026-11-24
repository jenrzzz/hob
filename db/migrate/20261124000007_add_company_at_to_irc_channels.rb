# When a room last had company (IRC.md, "Company"): a person reading it, or
# someone who lives without its company saying something there unprompted.
# The lives kept to it (`life.company`) run only within a while of this.
class AddCompanyAtToIrcChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :irc_channels, :company_at, :datetime
  end
end
