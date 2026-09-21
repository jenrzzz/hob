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
  class WardController < ApplicationController
    before_action :require_worker_or_person!, only: :create_run
    before_action :require_trusted!, except: :create_run

    rescue_from Ward::Invalid do |e|
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

    private

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
