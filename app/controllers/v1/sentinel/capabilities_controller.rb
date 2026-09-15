module V1
  module Sentinel
    # GET  /v1/sentinel/capabilities        an agent sees what it may ask for, with the
    #                                       effect it can expect; a person sees everything
    # POST /v1/sentinel/capabilities        { name, description, input_schema, kind, realm,
    #                                         venue: webhook|poll, config }   people only
    # PATCH/DELETE /v1/sentinel/capabilities/:name
    class CapabilitiesController < ApplicationController
      self.agent_actions = %i[index show]

      before_action :require_trusted!, only: %i[create update destroy]

      def index
        caps = Capability.enabled.order(:name).to_a
        caps = caps.filter_map { |c| (effect = effect_for(c)) && [ c, effect ] }
        render json: caps.map { |c, effect| serialize(c).merge(effect: effect) }
      end

      def show
        cap = Capability.enabled.find_by!(name: params[:name])
        effect = effect_for(cap)
        raise ActiveRecord::RecordNotFound if effect.nil? && Current.principal.agent?

        render json: serialize(cap).merge(effect: effect)
      end

      def create
        cap = Capability.create!(capability_params)
        render json: serialize(cap, config: true), status: :created
      end

      def update
        cap = Capability.find_by!(name: params[:name])
        cap.update!(capability_params)
        render json: serialize(cap, config: true)
      end

      def destroy
        cap = Capability.find_by!(name: params[:name])
        raise ::Sentinel::Invalid, "native capabilities are disabled, not deleted" if cap.native?

        cap.destroy!
        head :no_content
      end

      private

      # What this agent can expect from asking: nil when a rule denies it,
      # nothing permits it, or its clearance is too low. People see "any".
      def effect_for(cap)
        return "any" unless Current.principal.agent?
        return nil if clearance_rank < cap.realm_rank

        rule = SentinelPolicy.resolve(principal: Current.principal, capability: cap.name)
        rule && rule.effect != "deny" ? rule.effect : nil
      end

      def capability_params
        params.permit(:name, :description, :kind, :realm, :venue, :enabled).to_h.tap do |h|
          h[:input_schema] = hash_param(:input_schema) if params[:input_schema].present?
          h[:config] = hash_param(:config) if params[:config].present?
        end
      end

      def serialize(cap, config: false)
        {
          name: cap.name, description: cap.description, input_schema: cap.input_schema,
          kind: cap.kind, realm: cap.realm, venue: cap.venue, enabled: cap.enabled
        }.tap { |h| h[:config] = cap.config.except("secret") if config }
      end
    end
  end
end
