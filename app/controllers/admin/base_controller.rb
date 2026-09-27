# The admin pages: server-rendered, for people. The API (ApplicationController)
# authenticates bearer keys; these authenticate a cookie session that
# SessionsController opens after the household's OIDC provider vouches for
# someone. Only a linked, trusted (human) principal gets in, and a session
# lasts at most SESSION_TTL however active it is.
module Admin
  class BaseController < ActionController::Base
    SESSION_TTL = 12.hours

    layout "admin"
    protect_from_forgery with: :exception
    before_action :require_person!
    helper_method :current_person

    private

    def current_person
      Current.principal
    end

    def require_person!
      person = session_person
      return redirect_to login_path if person.nil?

      Current.principal = person
      Current.surface = "admin"
    end

    def session_person
      signed_in_at = session[:signed_in_at].to_i
      return nil if signed_in_at.zero? || Time.at(signed_in_at) < SESSION_TTL.ago

      person = Principal.find_by(id: session[:principal_id])
      # Unlinking a principal (or relinking it elsewhere) ends its sessions.
      return nil unless person&.trusted?
      return nil if session[:oidc_subject] && person.oidc_subject != session[:oidc_subject]

      person
    end
  end
end
