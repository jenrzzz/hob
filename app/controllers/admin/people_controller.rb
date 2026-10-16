module Admin
  # Who the household knows (PEOPLE.md), for the people it belongs to: the
  # open loops, longest-waiting first, and everyone hob has met, each with
  # the brief an agent would read. Changes go through agents and the
  # sentinel, or hob:people:* from a terminal; this page only shows.
  class PeopleController < BaseController
    def index
      @loops = People.loops("limit" => 100)
      @people = People.list({ "q" => params[:q].presence, "limit" => 200 }.compact)
    rescue People::Invalid => e
      redirect_to admin_people_path, alert: e.message
    end

    def show
      @brief = People.get("person" => params[:id], "events" => 50)
    rescue People::NotFound
      raise ActiveRecord::RecordNotFound
    end
  end
end
