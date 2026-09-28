# The companion app's sign-in, in the browser sheet it opens
# (ASWebAuthenticationSession): the person signs in as for /admin, confirms,
# and hob redirects to hob://signed-in with a one-time code (SignInGrant) the
# app trades for a key at POST /v1/app_sessions.
#
#   GET /app/sign_in?redirect_uri=hob://signed-in&state=…&code_challenge=…
#                    &code_challenge_method=S256&device=Jenner's%20iPhone
class AppSignInsController < Admin::BaseController
  REDIRECT_URI = "hob://signed-in"

  before_action :validate!

  def new
    @surface = surface
  end

  def create
    return redirect_back_to_app(error: "access_denied") if params[:cancel].present?

    code = SignInGrant.issue!(principal: current_person, code_challenge: params[:code_challenge], surface: surface)
    Rails.logger.info("app sign-in: #{current_person.name} signed in #{surface}")
    redirect_back_to_app(code: code)
  end

  private

  # Everything the app sent must be exactly what we expect; the redirect
  # target above all, since the code travels in it.
  def validate!
    problem =
      if params[:redirect_uri] != REDIRECT_URI then "redirect_uri must be #{REDIRECT_URI}"
      elsif params[:code_challenge_method] != "S256" then "code_challenge_method must be S256"
      elsif !params[:code_challenge].to_s.match?(SignInGrant::CHALLENGE_FORMAT) then "code_challenge is malformed"
      elsif params[:state].blank? || params[:state].to_s.length > 200 then "state is missing"
      end
    return if problem.nil?

    @problem = problem
    render :invalid, status: :bad_request
  end

  def surface
    device = params[:device].to_s.squish.presence || "phone"
    "app:#{device.truncate(40, omission: '')}"
  end

  def redirect_back_to_app(**query)
    redirect_to "#{REDIRECT_URI}?#{query.merge(state: params[:state]).to_query}", allow_other_host: true
  end
end
