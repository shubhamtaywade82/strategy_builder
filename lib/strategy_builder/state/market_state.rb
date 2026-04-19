# frozen_string_literal: true

module StrategyBuilder
  module State
    VALID_REGIMES   = %i[trend_up trend_down range compression expansion chop].freeze
    VALID_SESSIONS  = %i[asia london ny asia_london_overlap london_ny_overlap closed].freeze
    VALID_BIASES    = %i[long short neutral].freeze
    VALID_VOLATILITY = %i[contracting normal expanding].freeze
    VALID_VOLUME    = %i[declining average expanding].freeze

    MarketState = Struct.new(
      :instrument,
      :snapshot_at,
      :primary_timeframe,
      :regime,
      :session,
      :higher_tf_bias,
      :mid_tf_structure,
      :lower_tf_state,
      :volatility,
      :volume,
      :liquidity,
      :bias,
      :raw_features,
      keyword_init: true
    ) do
      def to_llm_context
        {
          instrument:        instrument,
          snapshot_at:       snapshot_at&.iso8601,
          primary_timeframe: primary_timeframe,
          regime:            regime,
          session:           session,
          higher_tf_bias:    higher_tf_bias,
          mid_tf_structure:  mid_tf_structure,
          lower_tf_state:    lower_tf_state,
          volatility:        volatility,
          volume:            volume,
          bias:              bias,
          liquidity: {
            equal_highs:    liquidity&.dig(:equal_highs)&.first(3),
            equal_lows:     liquidity&.dig(:equal_lows)&.first(3),
            nearest_resist: liquidity&.dig(:nearest_resist),
            nearest_support: liquidity&.dig(:nearest_support)
          }
        }
      end

      def valid?
        return false if instrument.nil? || instrument.to_s.empty?
        return false unless VALID_REGIMES.include?(regime)
        return false unless VALID_BIASES.include?(bias)

        true
      end
    end
  end
end
