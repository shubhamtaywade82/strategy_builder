# frozen_string_literal: true

module StrategyBuilder
  module Patterns
    class PatternMiner
      MIN_SCORE = 0.3

      def self.mine(market_state)
        candidates = PatternLibrary.matching(
          regime: market_state.regime,
          bias:   market_state.bias
        )

        candidates.filter_map do |name, defn|
          score = score_pattern(name, defn, market_state)
          next if score < MIN_SCORE

          {
            name:         name,
            score:        score.round(3),
            evidence:     collect_evidence(defn, market_state),
            description:  defn[:description],
            entry_type:   defn[:entry_type],
            confirmation: defn[:confirmation],
            invalidation: defn[:invalidation]
          }
        end.sort_by { |p| -p[:score] }
      end

      private

      def self.score_pattern(name, defn, state)
        score = 0.0

        # Base: regime match (mandatory in .matching but worth scoring)
        score += 0.30 if defn[:required_regime].include?(state.regime)

        # Volatility-specific bonuses
        score += 0.20 if state.volatility == :contracting && name == :compression_breakout
        score += 0.15 if state.volatility == :expanding && %i[pullback_continuation session_breakout].include?(name)

        # Volume confirmation
        score += 0.20 if state.volume == :expanding

        # Higher-TF alignment
        score += 0.15 if state.higher_tf_bias != :neutral

        # Liquidity context
        liquidity = state.liquidity || {}
        score += 0.10 if liquidity[:equal_highs]&.any? || liquidity[:equal_lows]&.any?

        # Session bonus
        score += 0.05 if %i[london london_ny_overlap].include?(state.session)

        score.clamp(0.0, 1.0)
      end

      def self.collect_evidence(defn, state)
        evidence = []
        evidence << "Regime #{state.regime} matches pattern requirement" if defn[:required_regime].include?(state.regime)
        evidence << "Higher-TF bias: #{state.higher_tf_bias}" if state.higher_tf_bias != :neutral
        evidence << "Volatility: #{state.volatility}" unless state.volatility == :normal
        evidence << "Volume: #{state.volume}" if state.volume == :expanding
        evidence << "Session: #{state.session}" if %i[london london_ny_overlap].include?(state.session)
        evidence
      end
    end
  end
end
