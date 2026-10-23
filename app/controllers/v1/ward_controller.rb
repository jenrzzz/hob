module V1
  # The ward (WARD.md): where checks post their reports and people read the
  # findings. Agents get nothing here; they ask the sentinel for `ward.status`.
  #
  #   POST /v1/ward/runs                { check, exit_code, lines | output, started_at?, finished_at?, mission? }   a worker or a person
  #   GET  /v1/ward/runs?check=&limit=
  #   GET  /v1/ward/status
  #   GET  /v1/ward/findings?state=open|acknowledged|resolved|all&check=
  #   POST /v1/ward/findings/:id/ack    { note?, until? }
  #   POST /v1/ward/findings/:id/unack
  #   GET  /v1/ward/notes?subject=  ·  POST /v1/ward/notes { subject, body }
  #
  # Threats (THREATS.md), for people; observations for the worker too:
  #
  #   GET  /v1/ward/threats?state=open|closed|all|<status>  ·  GET /v1/ward/threats/:id
  #   POST /v1/ward/threats                       { kind, title, cve_ids, component, fixed_versions, gotchas, source, claimed_severity, exploited, actor, target, window_days, upstream }
  #   POST /v1/ward/threats/:id/notes             { body, evidence?, indicator?, satisfies? }
  #   POST /v1/ward/threats/:id/retriage
  #   POST /v1/ward/threats/:id/accept_risk       { reason, review_days? }
  #   POST /v1/ward/threats/:id/standdown         { reason }
  #   POST /v1/ward/threats/:id/await_upstream    { source: github|dockerhub, repository, current?, fixed?, poll_hours? }
  #   POST /v1/ward/threats/:id/extend            { days? }
  #   POST /v1/ward/threats/:id/gotchas/:index    { evidence }
  #   POST /v1/ward/threats/:id/proposals/:proposal/confirm|decline   { note? }
  #   GET  /v1/ward/assets  ·  POST /v1/ward/assets/sync  ·  PATCH /v1/ward/assets/:id { components?, exposure? }
  #   POST /v1/ward/observations                  { asset, component, version, digest?, started_at? }   worker or person
  class WardController < ApplicationController
    WORKER_ACTIONS = %i[create_run create_observation].freeze

    before_action :require_worker_or_person!, only: WORKER_ACTIONS
    before_action :require_trusted!, except: WORKER_ACTIONS

    rescue_from Ward::Invalid, WardThreat::BadTransition do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def create_run
      run = Ward::Ingest.call(
        check: params.require(:check), exit_code: params.require(:exit_code), lines: lines_param,
        principal: Current.principal, started_at: time_param(:started_at), finished_at: time_param(:finished_at),
        mission_id: params[:mission].presence
      )
      render json: run.as_json_for_ward, status: :created
    end

    def runs
      rows = WardRun.recent.limit(params[:limit].presence&.to_i&.clamp(1, 200) || 20)
      rows = rows.where(check_slug: params[:check]) if params[:check].present?
      render json: rows.map(&:as_json_for_ward)
    end

    def status
      render json: Ward.status
    end

    def findings
      Ward::Sweep.call
      rows = WardFinding.in_state(params[:state].presence || "open").by_severity.limit(500)
      rows = rows.where(check_slug: params[:check]) if params[:check].present?
      render json: rows.map(&:as_json_for_ward)
    end

    def ack
      finding = WardFinding.find(params[:id])
      finding.acknowledge!(by: Current.principal, note: params[:note], until_at: time_param(:until))
      render json: finding.as_json_for_ward
    end

    def unack
      finding = WardFinding.find(params[:id])
      finding.unacknowledge!
      render json: finding.as_json_for_ward
    end

    def notes
      rows = WardNote.recent.limit(200)
      rows = rows.about(params[:subject]) if params[:subject].present?
      render json: rows.map(&:as_json_for_ward)
    end

    def create_note
      note = WardNote.create!(subject: params.require(:subject), body: params.require(:body), author: Current.principal)
      render json: note.as_json_for_ward, status: :created
    end

    def threats
      rows = WardThreat.in_state(params[:state]).by_severity.limit(params[:limit].presence&.to_i&.clamp(1, 500) || 100)
      render json: rows.map(&:as_json_for_ward)
    rescue ArgumentError => e
      raise Ward::Invalid, e.message
    end

    def threat
      render json: find_threat.as_json_for_ward(history: true)
    end

    def create_threat
      threat, merged = Ward::Threats.report!(params.permit!.to_h.slice(*Ward::Threats::REPORT_KEYS), by: Current.principal)
      render json: threat.as_json_for_ward.merge("merged" => merged), status: merged ? :ok : :created
    end

    def threat_note
      threat = find_threat
      Ward::Threats.note!(threat, body: params[:body], by: Current.principal, evidence: params[:evidence],
                                  indicator: ActiveModel::Type::Boolean.new.cast(params[:indicator]) || false, satisfies: params[:satisfies].presence)
      render json: threat.reload.as_json_for_ward(history: true), status: :created
    end

    def threat_retriage
      render json: Ward::Threats.triage!(find_threat, by: Current.principal).as_json_for_ward
    end

    def threat_accept_risk
      render json: Ward::Threats.accept_risk!(find_threat, reason: params[:reason], by: Current.principal, review_days: params[:review_days]).as_json_for_ward
    end

    def threat_standdown
      render json: Ward::Threats.standdown!(find_threat, reason: params[:reason], by: Current.principal).as_json_for_ward
    end

    def threat_await_upstream
      spec = params.permit(:source, :repository, :current, :fixed, :poll_hours).to_h
      render json: Ward::Threats.await_upstream!(find_threat, upstream: spec, by: Current.principal).as_json_for_ward
    end

    def threat_extend
      render json: Ward::Threats.extend!(find_threat, by: Current.principal, days: params[:days]).as_json_for_ward
    end

    def threat_gotcha
      threat = find_threat
      Ward::Threats.satisfy!(threat, params[:index], evidence: params.require(:evidence), by: Current.principal)
      render json: threat.as_json_for_ward
    end

    def threat_decide
      threat = Ward::Threats.decide!(find_threat, params[:proposal], decision: params[:decision], by: Current.principal, note: params[:note])
      render json: threat.as_json_for_ward
    end

    def assets
      rows = WardAsset.by_name
      rows = rows.present unless params[:all].present?
      render json: rows.map(&:as_json_for_ward)
    end

    def sync_assets
      render json: Ward::Inventory.sync!
    rescue Ward::Error => e
      render json: { error: e.message }, status: :bad_gateway
    end

    def declare_asset
      asset = find_asset(params[:id]) || raise(ActiveRecord::RecordNotFound)
      declared = asset.declared.dup
      declared["components"] = Array(params[:components]).map { |c| c.to_s.strip.downcase }.compact_blank if params.key?(:components)
      if params.key?(:exposure)
        raise Ward::Invalid, "exposure must be one of #{WardAsset::EXPOSURES.join(', ')}" unless params[:exposure].blank? || WardAsset::EXPOSURES.include?(params[:exposure])

        declared["exposure"] = params[:exposure].presence
      end
      asset.update!(declared: declared.compact_blank)
      render json: asset.as_json_for_ward
    end

    # A probe's reading: what answered on the wire, posted by the ward worker
    # or a person. The cross-check on what Coolify says runs.
    def create_observation
      asset = find_asset(params.require(:asset)) || raise(Ward::Invalid, "no asset #{params[:asset].inspect}; see GET /v1/ward/assets")
      observation = asset.observe!(component: params.require(:component), version: params[:version], digest: params[:digest],
                                   source: Current.principal.trusted? ? "person" : "probe", principal: Current.principal,
                                   started_at: time_param(:started_at))
      render json: observation.as_json_for_ward, status: :created
    end

    private

    def find_threat
      WardThreat.find(params[:id])
    end

    # By id, ref, or name.
    def find_asset(key)
      WardAsset.find_by(id: key) || WardAsset.find_by(ref: key) || WardAsset.present.find_by(name: key)
    end

    def lines_param
      return params[:output] if params[:output].is_a?(String)

      lines = params[:lines]
      lines = lines.to_unsafe_h.values if lines.respond_to?(:to_unsafe_h)
      raise Ward::Invalid, "lines (an array) or output (text) is required" if lines.blank?

      Array(lines)
    end

    def time_param(name)
      raw = params[name]
      return nil if raw.blank?

      Time.zone.parse(raw.to_s) || raise(Ward::Invalid, "#{name} must be an ISO8601 date-time")
    rescue ArgumentError
      raise Ward::Invalid, "#{name} must be an ISO8601 date-time"
    end
  end
end
