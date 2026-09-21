# Error reporting. The DSN comes from SENTRY_DSN (the SDK reads it itself), so
# this sends only where that is set; everywhere else it captures nothing.
#
# hob's request bodies are prompts and replies, its query strings and SQL
# carry the same, and none of that may leave the box. The SDK's defaults
# already withhold them; they are pinned here so an upgrade can't quietly
# change that (test/initializers/sentry_test.rb holds the line).
Sentry.init do |config|
  config.release = ENV["SENTRY_RELEASE"] || ENV["SOURCE_COMMIT"] # Coolify sets SOURCE_COMMIT; the image has no .git

  config.data_collection.http_bodies = []
  config.data_collection.url_query_params = false
  config.data_collection.cookies = false
  config.data_collection.database_query_data = false
  config.data_collection.stack_frame_variables = false
  config.breadcrumbs_logger = []

  # Errors only, no tracing; and no sentry-trace / baggage headers on hob's
  # own calls out to providers, webhooks, ntfy, and Coolify.
  config.propagate_traces = false

  # Rails.error.report is how hob reports what it rescues and carries on
  # from: a failed stream, a sentinel request or petition that errored, a
  # ledger write, a ping that didn't go out.
  config.rails.register_error_subscriber = true
end

# Who was asking, read when the event is made so it holds on the threads
# ActionController::Live runs streaming actions on too.
Sentry.add_global_event_processor do |event, _hint|
  who = { principal: Current.principal&.name, surface: Current.surface, clearance: Current.clearance }.compact
  event.tags = who.merge(event.tags)
  event
end
