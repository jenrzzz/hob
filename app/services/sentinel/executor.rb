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
    ANSWERS = [ Gateway::Error, Todos::Error, Budgets::Error, Webhook::Error, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ArgumentError ].freeze

    def run!(request)
      capability = request.capability
      as_agent(request) do
        case capability.venue
        when "native" then request.finish!(capability.handler.new(request).call)
        when "webhook" then request.finish!(Webhook.deliver(capability, request))
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
