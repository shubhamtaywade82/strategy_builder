# frozen_string_literal: true

module StrategyBuilder
  module Agent
    module Roles
      class Observer
        SCHEMA = {
          "type" => "object",
          "required" => %w[narrative session_context key_levels no_trade_context],
          "properties" => {
            "narrative"        => { "type" => "string" },
            "session_context"  => { "type" => "string" },
            "key_levels"       => { "type" => "array", "items" => { "type" => "string" } },
            "no_trade_context" => { "type" => "array", "items" => { "type" => "string" } }
          }
        }.freeze

        def initialize(client: StrategyBuilder.ollama_client)
          @planner = OllamaGeneratePlanner.build(client)
          @logger  = StrategyBuilder.logger
        end

        # Deterministic values (regime, bias) never overwritten by LLM.
        # LLM only adds narrative context.
        def classify(market_state)
          prompt = Prompts::ObserverPrompt.build(market_state)
          raw    = invoke(prompt, SCHEMA)

          {
            confirmed_regime: market_state.regime,
            narrative:        raw["narrative"] || "",
            session_context:  raw["session_context"] || "",
            key_levels:       Array(raw["key_levels"]),
            no_trade_context: Array(raw["no_trade_context"])
          }
        rescue StandardError => e
          @logger.warn { "Observer failed: #{e.message}" }
          { confirmed_regime: market_state.regime, narrative: "", session_context: "", key_levels: [], no_trade_context: [] }
        end

        private

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
