module V1
  module Sentinel
    # The rules. People only.
    # GET    /v1/sentinel/policies?agent=
    # POST   /v1/sentinel/policies { agent?, capability, effect, constraints?, limits?, guidance? }
    # PATCH  /v1/sentinel/policies/:id
    # DELETE /v1/sentinel/policies/:id
    class PoliciesController < ApplicationController
      before_action :require_trusted!

      def index
        rules = SentinelPolicy.includes(:principal).order(:principal_id, :capability)
        rules = rules.where(principal: Principal.find_by!(name: params[:agent])) if params[:agent].present?
        render json: rules.map { |r| serialize(r) }
      end

      def create
        rule = SentinelPolicy.create!(policy_params)
        render json: serialize(rule), status: :created
      end

      # A guidance change writes through the audited path (GuidanceChange) —
      # the same one a petition's approval and the admin UI use — so every
      # edit to it is on the record no matter which door it came through.
      # Effect, constraints, and limits are unaudited config, as before.
      def update
        rule = SentinelPolicy.find(params[:id])
        attrs = policy_params
        if attrs.key?(:guidance)
          guidance = attrs.delete(:guidance)
          rule.update!(attrs) if attrs.present?
          rule.update_guidance!(guidance, source: "admin", decided_by: "human", decider: Current.principal,
                                rationale: params[:rationale].presence)
        else
          rule.update!(attrs)
        end
        render json: serialize(rule)
      end

      def destroy
        SentinelPolicy.find(params[:id]).destroy!
        head :no_content
      end

      private

      def policy_params
        params.permit(:capability, :effect, :guidance).to_h.tap do |h|
          h[:principal] = params[:agent].presence && Principal.find_by!(name: params[:agent]) if params.key?(:agent)
          h[:constraints] = hash_param(:constraints) || {} if params.key?(:constraints)
          h[:limits] = hash_param(:limits) || {} if params.key?(:limits)
        end
      end

      def serialize(rule)
        { id: rule.id, agent: rule.principal&.name, capability: rule.capability, effect: rule.effect,
          constraints: rule.constraints, limits: rule.limits, guidance: rule.guidance, updated_at: rule.updated_at }
      end
    end
  end
end
