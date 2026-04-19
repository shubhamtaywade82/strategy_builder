# frozen_string_literal: true

module StrategyBuilder
  module Agent
    module Prompts
      class ObserverPrompt
        SYSTEM = <<~PROMPT.freeze
          You are the market observer on a crypto futures research desk.
          Your role is to describe what you see — not to propose trades.
          Given multi-timeframe market state data, output ONLY valid JSON.
          Describe: session context, narrative summary, key price levels, and any no-trade conditions.
          Do not predict price direction. Do not mention indicator names unless they appear in the input.
          Do not say "buy" or "sell". Output the JSON object directly with no markdown.
        PROMPT

        def self.build(market_state)
          context = JSON.pretty_generate(market_state.to_llm_context)
          {
            system: SYSTEM,
            user:   "Market state:\n#{context}\n\nOutput JSON only."
          }
        end
      end
    end
  end
end
