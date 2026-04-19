# frozen_string_literal: true

module StrategyBuilder
  module Patterns
    class PatternLibrary
      PATTERNS = {
        compression_breakout: {
          required_regime:  %i[compression],
          required_bias:    %i[long short neutral],
          confirmation:     %w[volume_surge range_break direction_bias],
          invalidation:     ["no volume on break", "immediate reversal below level", "range resumes"],
          entry_type:       :limit,
          description:      "Volatility contraction then expansion with volume"
        },
        pullback_continuation: {
          required_regime:  %i[trend_up trend_down],
          required_bias:    %i[long short],
          confirmation:     %w[higher_tf_trend_bullish lower_tf_pullback_to_ema structure_hold trigger_candle],
          invalidation:     ["break of higher swing low", "loss of trend structure", "volume divergence on pullback"],
          entry_type:       :limit,
          description:      "MTF trend pullback to key level then continuation"
        },
        session_breakout: {
          required_regime:  %i[range compression],
          required_bias:    %i[long short neutral],
          confirmation:     %w[asia_range_defined session_high_break volume_confirmation],
          invalidation:     ["session ends", "no volume on break", "immediate reversal below level"],
          entry_type:       :limit,
          description:      "Range from prior session broken with volume"
        },
        liquidity_sweep_reversal: {
          required_regime:  %i[range expansion],
          required_bias:    %i[long short neutral],
          confirmation:     %w[rejection_candle volume_divergence retest_below_level],
          invalidation:     ["continuation beyond sweep", "no reversal within 3 candles", "increased volume on continuation"],
          entry_type:       :limit,
          description:      "Stop hunt above/below key level then reversal"
        },
        vwap_reclaim: {
          required_regime:  %i[range trend_up trend_down],
          required_bias:    %i[long short neutral],
          confirmation:     %w[price_reclaims_vwap structure_bullish_shift volume_on_reclaim momentum_confirmation],
          invalidation:     ["price falls back under VWAP", "no volume on reclaim", "bearish structure intact"],
          entry_type:       :limit,
          description:      "Price reclaims VWAP after dip with structural shift"
        },
        failed_breakout_reversal: {
          required_regime:  %i[range expansion],
          required_bias:    %i[long short neutral],
          confirmation:     %w[breakout_attempt retest_below_level rejection_candle volume_divergence],
          invalidation:     ["breakout holds for 3 candles", "no rejection wick", "volume confirms breakout"],
          entry_type:       :limit,
          description:      "Breakout fails and reverses back through level"
        }
      }.freeze

      def self.all
        PATTERNS
      end

      def self.matching(regime:, bias:)
        PATTERNS.select do |_, defn|
          defn[:required_regime].include?(regime) &&
            (defn[:required_bias].include?(bias) || bias == :neutral)
        end
      end

      def self.names
        PATTERNS.keys
      end

      def self.get(name)
        PATTERNS[name.to_sym]
      end
    end
  end
end
