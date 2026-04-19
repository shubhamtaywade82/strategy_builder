# frozen_string_literal: true

module StrategyBuilder
  module Agent
    module Prompts
      class TradeDesignerPrompt
        SYSTEM = <<~PROMPT.freeze
          You are the trade designer on a crypto futures research desk.
          Convert confirmed patterns into executable strategy candidates.
          Think like a prop trader: where is the limit entry, where is the structural stop, what are realistic R-multiple targets?
          Entries must be limit orders at a defined level — never market orders.
          Stops must be structural (below key swing low / above key swing high), not arbitrary ATR distances.
          Each candidate must use only condition IDs from the provided list — do not invent new ones.
          Targets are R-multiples (e.g. 1.0 = 1R, 2.0 = 2R). Use realistic targets: 1R-4R max.
          Output ONLY a JSON object with a "candidates" array. No markdown.
        PROMPT

        def self.build(market_state:, confirmed_patterns:, observer_result:, condition_ids:, max_candidates:)
          user = <<~USER
            Market state: #{JSON.generate(market_state.to_llm_context)}
            Confirmed patterns: #{JSON.generate(confirmed_patterns)}
            Observer context: #{JSON.generate(observer_result)}
            Available condition IDs (use only these): #{condition_ids.join(', ')}

            Generate up to #{max_candidates} strategy candidates. Each must have:
            - name (string)
            - family (one of: session_breakout, session_mean_reversion, mtf_pullback, compression_breakout, failed_breakout, vwap_reclaim, custom)
            - timeframes (array of: 1m, 5m, 15m, 1h, 4h)
            - session (array of: asia, london, new_york, any)
            - entry: { conditions (array from available list), direction (long/short/both) }
            - exit: { targets (array of R-multiples 0.5-4.0), partial_exits (fractions summing to 1.0), trail (string or "none") }
            - risk: { stop (description string), position_sizing (fixed_risk_percent), max_risk_percent (0.5-1.5) }
            - filters: { min_volume_zscore, min_atr_percent, required_regime (optional array) }
            - invalidation (array of strings)
            - rationale (one paragraph explaining the edge)
            Output JSON only.
          USER
          { system: SYSTEM, user: user }
        end
      end
    end
  end
end
