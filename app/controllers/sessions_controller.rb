# Signing in to the admin pages. OmniAuth (config/initializers/omniauth.rb)
# runs the OIDC dance and hands the result to #create; a principal linked to
# that subject (`hob:link`) who is a person gets a session.
class SessionsController < ActionController::Base
  layout "admin"
  protect_from_forgery with: :exception
  # The provider's redirect carries state, nonce and PKCE; OmniAuth checks
  # those. The developer form posts here without a Rails token.
  skip_forgery_protection only: :create

  helper_method :current_person

  def new
    @provider = oidc_configured? ? "oidc" : "developer"
  end

  def create
    auth = request.env["omniauth.auth"]
    person = person_for(auth)
    if person.nil?
      @subject = auth.uid
      @name = auth.info&.name.presence || auth.info&.email
      Rails.logger.info("admin sign-in refused: no person linked to #{auth.provider} subject #{auth.uid}")
      return render :unlinked, status: :forbidden
    end

    return_to = session[:return_to].to_s
    reset_session
    session[:principal_id] = person.id
    session[:oidc_subject] = person.oidc_subject if auth.provider.to_s == "oidc"
    session[:signed_in_at] = Time.current.to_i
    # Back to where sign-in interrupted: a path on this host, nothing else.
    redirect_to return_to.match?(%r{\A/(?![/\\])}) ? return_to : admin_root_path
  end

  def failure
    flash[:alert] = "Sign-in failed: #{params[:message].to_s.humanize.presence || 'unknown error'}"
    redirect_to login_path
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Signed out."
  end

  private

  def current_person = nil

  def person_for(auth)
    person =
      if auth.provider.to_s == "oidc"
        Principal.find_by(oidc_subject: auth.uid)
      elsif auth.provider.to_s == "developer" && Rails.env.development?
        Principal.find_by(name: auth.uid)
      end
    person if person&.trusted?
  end

  def oidc_configured?
    ENV["HOB_OIDC_ISSUER"].present? || Rails.env.test?
  end
end
