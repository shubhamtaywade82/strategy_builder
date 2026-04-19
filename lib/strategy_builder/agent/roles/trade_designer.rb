# frozen_string_literal: true

module StrategyBuilder
  module Agent
    module Roles
      class TradeDesigner
        MAX_CANDIDATES = 3

        SCHEMA = {
          "type" => "object",
          "required" => %w[candidates],
          "properties" => {
            "candidates" => {
              "type"     => "array",
              "maxItems" => MAX_CANDIDATES,
              "items"    => { "type" => "object", "additionalProperties" => true }
            }
          }
        }.freeze

        def initialize(client: StrategyBuilder.ollama_client)
          @planner   = OllamaGeneratePlanner.build(client)
          @validator = CandidateValidator.new
          @logger    = StrategyBuilder.logger
        end

        # @return [Array<Hash>] validated strategy candidates
        def synthesize(market_state:, confirmed_patterns:, observer_result:)
          if confirmed_patterns.empty?
            @logger.info { "TradeDesigner: no confirmed patterns — using template fallback" }
            return template_fallback(market_state)
          end

          prompt = Prompts::TradeDesignerPrompt.build(
            market_state:       market_state,
            confirmed_patterns: confirmed_patterns,
            observer_result:    observer_result,
            condition_ids:      ConditionRegistry.condition_ids,
            max_candidates:     MAX_CANDIDATES
          )
          raw      = invoke(prompt, SCHEMA)
          raw_list = Array(raw["candidates"])

          raw_list.filter_map do |c|
            symbolized = CandidateParser.symbolize_keys_deep(c)
            result = @validator.validate(symbolized)
            if result[:valid]
              symbolized
            else
              @logger.warn { "TradeDesigner: invalid candidate '#{symbolized[:name]}': #{result[:errors].first(2).join(', ')}" }
              nil
            end
          end
        rescue StandardError => e
          @logger.warn { "TradeDesigner failed: #{e.message}" }
          template_fallback(market_state)
        end

        private

        def template_fallback(market_state)
          StrategyTemplates.for_regime(market_state.regime).first(2)
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
