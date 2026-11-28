module Sentinel
  # Carries out an allowed request at the *agent's* clearance and identity,
  # whoever's request is running (a person approving later runs it too).
  # Native and webhook venues finish inline; poll becomes a mission and the
  # request completes when the mission does. Execution failures are recorded
  # on the request, not raised: `failed` is an answer.
  module Executor
    module_function

    # Failures that answer the agent (a bad argument, a backend or webhook
    # that is away) rather than faults in hob; anything else is reported.
    ANSWERS = [ Gateway::Error, Todos::Error, Budgets::Error, Calendars::Error, Email::Error, Texts::Error, Notes::Error, Web::Error, Records::Error, People::Error, Ward::Error, Webhook::Error, Consoles::Error, Shells::Error, Commissions::Error, Irc::Error, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ArgumentError ].freeze

    def run!(request)
      capability = request.capability
      as_agent(request) do
        case capability.venue
        when "native" then finish_native!(request, capability.handler.new(request).call)
        when "webhook" then finish_webhook!(request, Webhook.deliver(capability, request))
        when "poll" then dispatch(request, capability)
        end
      end
      request
    rescue StandardError => e
      Rails.logger.error("sentinel request #{request.id} failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      unless ANSWERS.any? { |answer| e.is_a?(answer) }
        Rails.error.report(e, handled: true, severity: :error, source: "hob.sentinel",
                           context: { request: request.id, capability: request.capability&.name })
      end
      request.fail!("#{e.class.name.demodulize}: #{e.message}")
      request
    end

    # The images go to whoever is waiting on this request, in memory, and
    # nowhere else: the row keeps the result without them.
    def finish_native!(request, result)
      result, images = Native.split_images(result)
      request.images = images
      request.finish!(result)
    end

    # A surface may hand back images the same way (`_images`: [{ data, mimeType }]),
    # so a library can show an agent what it found. Only well-formed raster
    # images pass, and only a few; the rest of the answer is stored as usual.
    WEBHOOK_IMAGE_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
    WEBHOOK_IMAGE_LIMIT = 4

    def finish_webhook!(request, result)
      result, images = Native.split_images(result)
      request.images = images.select do |image|
        image.is_a?(Hash) && image["data"].is_a?(String) && WEBHOOK_IMAGE_TYPES.include?(image["mimeType"])
      end.first(WEBHOOK_IMAGE_LIMIT)
      request.finish!(result)
    end

    def dispatch(request, capability)
      assignee = capability.assignee
      raise Invalid, "#{capability.name} has no assignee to poll for it" if assignee.nil?

      mission = Mission.create!(
        assignee: assignee, created_by: request.principal, title: capability.name, brief: request.reason,
        payload: { "capability" => capability.name, "arguments" => request.arguments, "request" => request.id },
        realm: request.realm, sentinel_request_id: request.id
      )
      request.update!(status: "executing", mission_id: mission.id)
    end

    def as_agent(request, &block)
      Clearance.with(request.realm) do
        Current.set(principal: request.principal, surface: request.surface, clearance: request.realm, &block)
      end
    end
  end
end
