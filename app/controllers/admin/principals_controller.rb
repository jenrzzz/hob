module Admin
  # Everyone who holds hob keys, and their keys.
  class PrincipalsController < BaseController
    def index
      @principals = Principal.includes(:api_keys).order(:kind, :name)
      @realms = Realm.order(:rank).pluck(:slug)
      @principal = Principal.new(kind: "agent", max_clearance: "household")
    end

    def create
      @principal = Principal.new(params.expect(principal: %i[name kind max_clearance]))
      if @principal.save
        redirect_to admin_root_path(anchor: "principal-#{@principal.id}"), notice: "Added #{@principal.name}."
      else
        redirect_to admin_root_path, alert: @principal.errors.full_messages.to_sentence
      end
    end
  end
end
