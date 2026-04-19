# frozen_string_literal: true

module StrategyBuilder
  module Agent
    module Prompts
      class PatternAnalystPrompt
        SYSTEM = <<~PROMPT.freeze
          You are the pattern analyst on a crypto futures research desk.
          You receive a market state and a pre-scored list of candidate patterns.
          Your task: confirm which patterns are currently forming and explain the trigger logic.
          Do not invent new patterns. Only accept or reject patterns from the provided list.
          For each accepted pattern: what is the exact trigger condition, is this continuation or reversal,
          and what specific conditions would invalidate it?
          Output ONLY a JSON object with accepted_patterns and rejected_patterns arrays. No markdown.
        PROMPT

        def self.build(market_state:, mined_patterns:, observer_result:)
          pattern_summary = mined_patterns.map do |p|
            p.slice(:name, :score, :evidence, :description)
          end

          user = <<~USER
            Market state: #{JSON.generate(market_state.to_llm_context)}
            Observer notes: #{JSON.generate(observer_result)}
            Candidate patterns (pre-scored): #{JSON.generate(pattern_summary)}

            For each candidate: accept or reject.
            If accepted, provide: name, confidence (0.0-1.0), trigger (one sentence), continuation (true/false), invalidation (array of strings).
            If rejected, provide: name, reason (one sentence).
            Output JSON only.
          USER
          { system: SYSTEM, user: user }
        end
      end
    end
  end
end
