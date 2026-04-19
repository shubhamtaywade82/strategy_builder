# frozen_string_literal: true

module StrategyBuilder
  module Agent
    module Roles
      class Skeptic
        SCHEMA = {
          "type" => "object",
          "required" => %w[accepted],
          "properties" => {
            "accepted"         => { "type" => "boolean" },
            "rejection_reason" => { "type" => "string" },
            "concerns"         => { "type" => "array", "items" => { "type" => "string" } },
            "required_changes" => { "type" => "array", "items" => { "type" => "string" } }
          }
        }.freeze

        # Hard-reject lambdas checked before LLM (fast path — no API call needed)
        HARD_REJECTS = [
          ->(c, _s) { (c.dig(:exit, :targets) || []).map(&:to_f).max.to_f < 1.0 },
          ->(c, _s) { (c.dig(:entry, :conditions) || []).empty? },
          ->(c, s)  { s.regime == :chop && !%w[session_mean_reversion vwap_reclaim].include?(c[:family].to_s) }
        ].freeze

        def initialize(client: StrategyBuilder.ollama_client)
          @planner = OllamaGeneratePlanner.build(client)
          @logger  = StrategyBuilder.logger
        end

        # @return [Hash, nil] candidate (with skeptic_notes) if accepted; nil if rejected
        def review(candidate, market_state)
          if (reason = hard_reject_reason(candidate, market_state))
            @logger.info { "Skeptic hard-rejected '#{candidate[:name]}': #{reason}" }
            return nil
          end

          prompt = Prompts::SkepticPrompt.build(
            candidate:    candidate,
            market_state: market_state
          )
          raw    = invoke(prompt, SCHEMA)

          if raw["accepted"]
            candidate.merge(skeptic_notes: Array(raw["concerns"]))
          else
            @logger.info { "Skeptic rejected '#{candidate[:name]}': #{raw['rejection_reason']}" }
            nil
          end
        rescue StandardError => e
          @logger.warn { "Skeptic failed for '#{candidate[:name]}': #{e.message} — passing candidate through" }
          candidate.merge(skeptic_notes: ["Skeptic unavailable"])
        end

        private

        def hard_reject_reason(candidate, market_state)
          return "RR < 1.0" if HARD_REJECTS[0].call(candidate, market_state)
          return "no entry conditions" if HARD_REJECTS[1].call(candidate, market_state)
          return "chop regime + wrong family" if HARD_REJECTS[2].call(candidate, market_state)

          nil
        end

        def invoke(prompt_hash, schema)
          raw = @planner.run(
            prompt:        prompt_hash[:user],
            system_prompt: prompt_hash[:system],
            schema:        schema
          )
          raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : (CandidateParser.parse_json_loose(raw.to_s) || {})
        end
      end
    end
  end
end
