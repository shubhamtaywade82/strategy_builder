# frozen_string_literal: true

module StrategyBuilder
  class StrategyTemplates
    # Hardcoded strategy templates — the LLM mutates within bounds, not invents from scratch.
    TEMPLATES = [
      # 1. Session Breakout Continuation
      {
        name: "Asia Range Breakout",
        family: "session_breakout",
        timeframes: %w[15m 5m 1m],
        session: %w[london],
        entry: {
          conditions: %w[asia_range_defined session_high_break volume_confirmation]
        },
        exit: {
          targets: [1.0, 2.0, 3.0],
          partial_exits: [0.33, 0.33, 0.34],
          trail: "atr_1_5_after_1R"
        },
        risk: {
          stop: "below_asia_low",
          position_sizing: "fixed_risk_percent",
          max_risk_percent: 1.0
        },
        filters: {
          min_volume_zscore: 1.5,
          min_atr_percent: 0.4,
          required_regime: %w[normal expansion]
        },
        invalidation: %w[no_volume_confirmation failed_breakout session_end],
        parameter_ranges: {
          atr_multiplier_stop: [0.5, 2.0],
          trail_activation_r: [0.8, 1.5],
          min_range_atr_ratio: [0.5, 1.5]
        }
      },

      # 2. Session Range Mean Reversion
      {
        name: "Session Range Mean Reversion",
        family: "session_mean_reversion",
        timeframes: %w[15m 5m],
        session: %w[asia london new_york],
        entry: {
          conditions: %w[price_near_session_extreme rsi_divergence volume_decline]
        },
        exit: {
          targets: [0.5, 1.0],
          partial_exits: [0.5, 0.5],
          trail: "none"
        },
        risk: {
          stop: "beyond_session_extreme",
          position_sizing: "fixed_risk_percent",
          max_risk_percent: 0.75
        },
        filters: {
          max_atr_percent: 1.5,
          required_regime: %w[normal compression],
          min_candles_in_range: 10
        },
        invalidation: %w[breakout_confirmed trend_continuation high_volume_break],
        parameter_ranges: {
          extreme_threshold_pct: [0.8, 0.95],
          rsi_divergence_lookback: [5, 20]
        }
      },

      # 3. MTF Trend Pullback
      {
        name: "MTF Trend Pullback Entry",
        family: "mtf_pullback",
        timeframes: %w[1h 15m 5m],
        session: %w[london new_york london_ny],
        entry: {
          conditions: %w[higher_tf_trend_bullish lower_tf_pullback_to_ema structure_hold trigger_candle]
        },
        exit: {
          targets: [1.5, 2.5, 4.0],
          partial_exits: [0.33, 0.33, 0.34],
          trail: "atr_2_0_after_1_5R"
        },
        risk: {
          stop: "below_pullback_low",
          position_sizing: "fixed_risk_percent",
          max_risk_percent: 1.0
        },
        filters: {
          min_mtf_alignment: 0.4,
          min_volume_zscore: 1.0,
          required_structure: %w[bullish]
        },
        invalidation: %w[structure_break higher_tf_reversal volume_divergence],
        parameter_ranges: {
          ema_period: [10, 30],
          pullback_depth_atr: [0.5, 1.5],
          trigger_candle_type: %w[engulfing pin_bar inside_break]
        }
      },

      # 4. Compression to Expansion Breakout
      {
        name: "Compression Expansion Breakout",
        family: "compression_breakout",
        timeframes: %w[4h 1h 15m],
        session: %w[london new_york],
        entry: {
          conditions: %w[compression_detected range_break volume_surge direction_bias]
        },
        exit: {
          targets: [1.0, 2.0, 3.0],
          partial_exits: [0.4, 0.3, 0.3],
          trail: "atr_1_5_after_1R"
        },
        risk: {
          stop: "opposite_side_of_compression",
          position_sizing: "fixed_risk_percent",
          max_risk_percent: 1.0
        },
        filters: {
          max_compression_atr_ratio: 0.6,
          min_volume_zscore_on_break: 2.0,
          min_compression_candles: 8
        },
        invalidation: %w[false_breakout no_volume_follow_through retest_failure],
        parameter_ranges: {
          compression_threshold: [0.4, 0.7],
          volume_surge_zscore: [1.5, 3.0],
          min_bars_in_compression: [5, 20]
        }
      },

      # 5. Failed Breakout Reversal
      {
        name: "Failed Breakout Reversal",
        family: "failed_breakout",
        timeframes: %w[1h 15m 5m],
        session: %w[asia london new_york],
        entry: {
          conditions: %w[breakout_attempt retest_below_level rejection_candle volume_divergence]
        },
        exit: {
          targets: [1.0, 2.0],
          partial_exits: [0.5, 0.5],
          trail: "atr_1_0_after_1R"
        },
        risk: {
          stop: "above_false_breakout_high",
          position_sizing: "fixed_risk_percent",
          max_risk_percent: 0.75
        },
        filters: {
          min_rejection_wick_ratio: 0.6,
          max_time_above_level_candles: 5,
          required_volume_pattern: "declining_on_breakout"
        },
        invalidation: %w[sustained_breakout volume_confirmation_of_break structure_continuation],
        parameter_ranges: {
          rejection_lookback: [3, 10],
          wick_ratio_threshold: [0.5, 0.8]
        }
      },

      # 6. VWAP/MA Reclaim with Structure
      {
        name: "VWAP Reclaim Continuation",
        family: "vwap_reclaim",
        timeframes: %w[15m 5m 1m],
        session: %w[london new_york london_ny],
        entry: {
          conditions: %w[price_reclaims_vwap structure_bullish_shift volume_on_reclaim momentum_confirmation]
        },
        exit: {
          targets: [1.0, 1.5, 2.5],
          partial_exits: [0.33, 0.33, 0.34],
          trail: "atr_1_5_after_1R"
        },
        risk: {
          stop: "below_reclaim_candle_low",
          position_sizing: "fixed_risk_percent",
          max_risk_percent: 1.0
        },
        filters: {
          min_volume_zscore: 1.0,
          required_rsi_range: [40, 60],
          required_structure_shift: true
        },
        invalidation: %w[immediate_rejection_below_vwap no_follow_through session_end],
        parameter_ranges: {
          vwap_proximity_pct: [0.1, 0.5],
          confirmation_candles: [1, 3]
        }
      }
    ].freeze

    def self.all
      TEMPLATES
    end

    def self.by_family(family)
      TEMPLATES.select { |t| t[:family] == family }
    end

    def self.families
      TEMPLATES.map { |t| t[:family] }.uniq
    end

    # Return templates applicable to the given regime symbol (e.g. :compression, :trend_up).
    # Falls back to first 2 templates when no regime-specific match found.
    def self.for_regime(regime)
      regime_str = regime.to_s
      matched = TEMPLATES.select do |t|
        required = t.dig(:filters, :required_regime)
        required&.any? { |r| r.to_s == regime_str || regime_str.start_with?(r.to_s.split("_").first) }
      end
      matched.any? ? matched : TEMPLATES.first(2)
    end

    # Convert template to JSON for LLM consumption.
    def self.to_json_catalog
      TEMPLATES.map { |t| JSON.pretty_generate(t) }.join("\n\n---\n\n")
    end
  end
end
