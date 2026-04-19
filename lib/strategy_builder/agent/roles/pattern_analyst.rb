# frozen_string_literal: true

module StrategyBuilder
  module Agent
    module Roles
      class PatternAnalyst
        SCHEMA = {
          "type" => "object",
          "required" => %w[accepted_patterns rejected_patterns],
          "properties" => {
            "accepted_patterns" => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "required" => %w[name confidence trigger continuation invalidation],
                "properties" => {
                  "name"         => { "type" => "string" },
                  "confidence"   => { "type" => "number" },
                  "trigger"      => { "type" => "string" },
                  "continuation" => { "type" => "boolean" },
                  "invalidation" => { "type" => "array", "items" => { "type" => "string" } }
                }
              }
            },
            "rejected_patterns" => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "required" => %w[name reason],
                "properties" => {
                  "name"   => { "type" => "string" },
                  "reason" => { "type" => "string" }
                }
              }
            }
          }
        }.freeze

        def initialize(client: StrategyBuilder.ollama_client)
          @planner = OllamaGeneratePlanner.build(client)
          @logger  = StrategyBuilder.logger
        end

        # @return [Array<Hash>] confirmed patterns with LLM-added trigger/confidence
        def analyze(market_state:, mined_patterns:, observer_result:)
          return [] if mined_patterns.empty?

          prompt = Prompts::PatternAnalystPrompt.build(
            market_state:    market_state,
            mined_patterns:  mined_patterns,
            observer_result: observer_result
          )
          raw    = invoke(prompt, SCHEMA)
          llm_accepted = Array(raw["accepted_patterns"])

          llm_accepted.filter_map do |p|
            base = mined_patterns.find { |m| m[:name].to_s == p["name"].to_s } || {}
            next if base.empty?

            base.merge(
              llm_confidence: [p["confidence"].to_f, 1.0].min,
              trigger:        p["trigger"].to_s,
              continuation:   p["continuation"],
              invalidation:   Array(p["invalidation"]).any? ? Array(p["invalidation"]) : base[:invalidation]
            )
          end
        rescue StandardError => e
          @logger.warn { "PatternAnalyst failed: #{e.message}" }
          []
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
