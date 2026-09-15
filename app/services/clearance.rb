# The request clearance as Postgres sees it. Controllers SET app.clearance
# for the whole request (ApplicationController#with_clearance); this is for
# code that must run at a *different* clearance mid-request — the sentinel
# executing an agent's request after a person approved it — and put the
# previous value back.
module Clearance
  module_function

  def with(realm)
    connection = ActiveRecord::Base.connection
    previous = connection.select_value("SELECT current_setting('app.clearance', true)")
    connection.execute("SET app.clearance = #{connection.quote(realm)}")
    yield
  ensure
    if previous.present?
      connection.execute("SET app.clearance = #{connection.quote(previous)}")
    else
      connection.execute("RESET app.clearance")
    end
  end
end
