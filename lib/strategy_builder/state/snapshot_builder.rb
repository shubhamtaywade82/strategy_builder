# frozen_string_literal: true

module StrategyBuilder
  module State
    class SnapshotBuilder
      SESSION_MAP = {
        "asia"       => :asia,
        "london"     => :london,
        "new_york"   => :ny,
        "asia_london" => :asia_london_overlap,
        "london_ny"  => :london_ny_overlap,
        "off_hours"  => :closed
      }.freeze

      def self.build(instrument:, features:)
        regime    = RegimeClassifier.classify(features)
        session   = detect_session(features)
        liquidity = LiquidityMapBuilder.build(features)
        htf_bias  = higher_tf_bias(features)
        bias      = derive_bias(regime, htf_bias, features)

        MarketState.new(
          instrument:        instrument,
          snapshot_at:       Time.now.utc,
          primary_timeframe: features[:primary_timeframe],
          regime:            regime,
          session:           session,
          higher_tf_bias:    htf_bias,
          mid_tf_structure:  mid_tf_structure(features),
          lower_tf_state:    lower_tf_state(features),
          volatility:        volatility_label(features),
          volume:            volume_label(features),
          liquidity:         liquidity,
          bias:              bias,
          raw_features:      features
        )
      end

      private

      def self.detect_session(features)
        sessions = features.dig(:sessions) || []
        return :closed if sessions.empty?

        # Priority order: overlaps first, then primary sessions
        return :london_ny_overlap if sessions.include?("london_ny")
        return :asia_london_overlap if sessions.include?("asia_london")
        return :london if sessions.include?("london")
        return :ny if sessions.include?("new_york")
        return :asia if sessions.include?("asia")

        :closed
      end

      def self.higher_tf_bias(features)
        alignment = features.dig(:mtf_alignment, :alignment) || {}
        return :bullish if alignment[:aligned_bullish]
        return :bearish if alignment[:aligned_bearish]

        regime_label = alignment[:regime]
        case regime_label
        when :strong_bullish, :bullish then :bullish
        when :strong_bearish, :bearish then :bearish
        else :neutral
        end
      end

      def self.mid_tf_structure(features)
        per_tf = features[:per_timeframe_summary] || {}
        # Find a mid timeframe (15m or 30m preferred; fall back to primary)
        mid_tf = per_tf.keys.find { |k| %w[15m 30m].include?(k) } ||
                 per_tf.keys.find { |k| %w[1h 5m].include?(k) } ||
                 per_tf.keys.first

        return :unknown unless mid_tf

        structure = per_tf.dig(mid_tf, :structure)
        case structure
        when :bullish  then :higher_high_higher_low
        when :bearish  then :lower_high_lower_low
        when :ranging  then :ranging
        else :ranging
        end
      end

      def self.lower_tf_state(features)
        primary_tf = features[:primary_timeframe]
        structure  = features.dig(:structure, :structure)
        per_tf     = features[:per_timeframe_summary] || {}

        # Find a lower timeframe relative to primary
        lower_tf = lower_timeframe_for(primary_tf, per_tf.keys)
        lower_structure = per_tf.dig(lower_tf, :structure) if lower_tf

        case lower_structure
        when :bullish then :trending
        when :bearish then :trending
        when :ranging
          case structure
          when :bullish then :pullback_into_support
          when :bearish then :at_resistance
          else :compressing
          end
        else
          case structure
          when :bullish then :trending
          when :bearish then :trending
          else :compressing
          end
        end
      end

      def self.lower_timeframe_for(primary, available)
        order = %w[1d 4h 1h 30m 15m 5m 3m 1m]
        idx = order.index(primary.to_s)
        return nil unless idx

        order[(idx + 1)..].find { |tf| available.include?(tf) }
      end

      def self.volatility_label(features)
        regime = features.dig(:volatility, :regime)
        case regime
        when :compression then :contracting
        when :expansion   then :expanding
        else :normal
        end
      end

      def self.volume_label(features)
        zscore = features.dig(:volume, :volume_zscore) || 0.0
        if zscore >= 1.0 then :expanding
        elsif zscore <= -0.5 then :declining
        else :average
        end
      end

      def self.derive_bias(regime, htf_bias, features)
        structure = features.dig(:structure, :structure)

        case regime
        when :trend_up
          :long
        when :trend_down
          :short
        when :compression, :range, :chop, :expansion
          case htf_bias
          when :bullish then :long
          when :bearish then :short
          else
            case structure
            when :bullish then :long
            when :bearish then :short
            else :neutral
            end
          end
        else
          :neutral
        end
      end
    end
  end
end
