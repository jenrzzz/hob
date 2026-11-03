module V1
  module Sentinel
    # GET  /v1/sentinel/capabilities        an agent sees what it may ask for, with the
    #                                       effect it can expect; a person sees everything
    # POST /v1/sentinel/capabilities        { name, description, input_schema, kind, realm,
    #                                         venue: webhook|poll, config }   people only
    # PATCH/DELETE /v1/sentinel/capabilities/:name
    # GET  /v1/sentinel/capabilities?unaccepted=1   what surfaces proposed that nobody
    #                                               has accepted yet (people only)
    # POST /v1/sentinel/capabilities/:name/accept   { realm, kind } confirm or change
    #                                               the proposal, and enable it (people only)
    class CapabilitiesController < ApplicationController
      self.agent_actions = %i[index show]

      before_action :require_trusted!, only: %i[create update destroy accept]

      def index
        if params[:unaccepted].present? && !Current.principal.agent?
          return render json: Capability.unaccepted.order(:name).map { |c| serialize(c).merge(proposal(c)) }
        end

        caps = Capability.offered_to(Current.principal).order(:name).to_a
        caps = caps.filter_map { |c| (effect = effect_for(c)) && [ c, effect ] }
        render json: caps.map { |c, effect| serialize(c).merge(effect: effect) }
      end

      def show
        cap = Capability.offered_to(Current.principal).find_by!(name: params[:name])
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

      def accept
        cap = Capability.find_by!(name: params[:name])
        cap.accept!(by: Current.principal, realm: params[:realm], kind: params[:kind])
        render json: serialize(cap)
      rescue Capability::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
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
          kind: cap.kind, realm: cap.realm, venue: cap.venue, enabled: cap.enabled, accepted: cap.accepted?,
          contract_revision: cap.contract_revision, suspended: cap.suspended_reason, deprecated_at: cap.deprecated_at,
          sunset_at: cap.sunset_at
        }.compact.tap { |h| h[:config] = cap.config.except("secret", "previous_secret") if config }
      end

      # What a person is agreeing to by accepting: the rules that will reach
      # it (wildcards included) and the petitions it will grant.
      def proposal(cap)
        {
          surface: cap.plugin&.namespace || cap.config["surface"],
          owner: cap.plugin&.owner&.name,
          plugin_type: cap.plugin&.plugin_type,
          remote_name: cap.remote_name,
          rules: cap.reaching_rules.map { |r| { agent: r.principal&.name || "*", capability: r.capability, effect: r.effect } },
          petitions: cap.waiting_petitions.map { |p| { id: p.id, agent: p.principal.name, effect: p.effect } }
        }
      end
    end
  end
end
