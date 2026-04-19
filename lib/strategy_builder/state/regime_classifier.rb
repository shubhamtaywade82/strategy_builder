# frozen_string_literal: true

module StrategyBuilder
  module State
    class RegimeClassifier
      def self.classify(features)
        vol_regime  = features.dig(:volatility, :regime)
        structure   = features.dig(:structure, :structure)
        alignment   = features.dig(:mtf_alignment, :alignment) || {}
        aligned_bull = alignment[:aligned_bullish]
        aligned_bear = alignment[:aligned_bearish]

        case vol_regime
        when :compression
          :compression
        when :expansion
          if aligned_bull && structure == :bullish
            :trend_up
          elsif aligned_bear && structure == :bearish
            :trend_down
          else
            :expansion
          end
        when :normal
          if structure == :bullish && aligned_bull
            :trend_up
          elsif structure == :bearish && aligned_bear
            :trend_down
          elsif structure == :ranging
            :range
          else
            :chop  # directional structure without MTF alignment = conflicting
          end
        else
          :chop
        end
      end
    end
  end
end
