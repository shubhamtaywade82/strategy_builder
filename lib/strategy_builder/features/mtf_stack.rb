# frozen_string_literal: true

module StrategyBuilder
  class MtfStack
    # Compute trend alignment across multiple timeframes.
    # Input: Hash of { timeframe => Array<candle> }
    # Returns alignment score: -1.0 (full bearish) to +1.0 (full bullish)
    def self.alignment(mtf_candles, ema_period: 20)
      scores = {}

      mtf_candles.each do |tf, candles|
        next if candles.size < ema_period + 5

        closes = candles.map { |c| c[:close] }
        ema_vals = MomentumEngine.ema(closes, period: ema_period)
        current_close = closes.last
        current_ema = ema_vals.compact.last

        next if current_ema.nil?

        # Trend score: price relative to EMA + EMA direction
        price_vs_ema = current_close > current_ema ? 1 : -1

        ema_compact = ema_vals.compact
        ema_direction = if ema_compact.size >= 3
                          slope = ema_compact.last - ema_compact[-3]
                          slope > 0 ? 1 : -1
                        else
                          0
                        end

        scores[tf] = (price_vs_ema + ema_direction) / 2.0
      end

      return { alignment: 0.0, scores: {}, regime: :unknown } if scores.empty?

      alignment_score = scores.values.sum / scores.size.to_f

      {
        alignment: alignment_score.round(3),
        scores: scores,
        regime: classify_alignment(alignment_score),
        aligned_bullish: scores.values.all? { |s| s > 0 },
        aligned_bearish: scores.values.all? { |s| s < 0 },
        conflicting: scores.values.any? { |s| s > 0 } && scores.values.any? { |s| s < 0 }
      }
    end

    # Detect pullback opportunities: higher TF trending, lower TF pulling back.
    def self.pullback_opportunities(mtf_candles, higher_tf:, lower_tf:, ema_period: 20)
      higher = mtf_candles[higher_tf]
      lower = mtf_candles[lower_tf]
      return nil unless higher && lower

      higher_trend = trend_direction(higher, ema_period: ema_period)
      lower_trend = trend_direction(lower, ema_period: ema_period)

      if higher_trend == :bullish && lower_trend == :bearish
        { type: :bullish_pullback, higher_tf: higher_tf, lower_tf: lower_tf }
      elsif higher_trend == :bearish && lower_trend == :bullish
        { type: :bearish_pullback, higher_tf: higher_tf, lower_tf: lower_tf }
      end
    end

    def self.trend_direction(candles, ema_period: 20)
      return :unknown if candles.size < ema_period + 5

      closes = candles.map { |c| c[:close] }
      ema_vals = MomentumEngine.ema(closes, period: ema_period)
      current = closes.last
      ema_current = ema_vals.compact.last

      return :unknown if ema_current.nil?

      current > ema_current ? :bullish : :bearish
    end

    # Order timeframes coarse → fine using Configuration::VALID_TIMEFRAMES (not Hash insertion order).
    def self.sorted_mtf_keys(keys)
      rank = Configuration::VALID_TIMEFRAMES.each_with_index.to_h
      keys.sort_by { |k| rank.fetch(k.to_s, 999) }.reverse
    end

    # Full MTF profile for LLM consumption.
    def self.profile(mtf_candles)
      align = alignment(mtf_candles)

      pullbacks = []
      sorted = sorted_mtf_keys(mtf_candles.keys)
      sorted.each_cons(2) do |higher_tf, lower_tf|
        pb = pullback_opportunities(mtf_candles, higher_tf: higher_tf, lower_tf: lower_tf)
        pullbacks << pb if pb
      end

      per_tf = mtf_candles.transform_values do |candles|
        next { trend: :unknown } if candles.size < 25

        {
          trend: trend_direction(candles),
          structure: StructureDetector.structure(candles),
          volatility_regime: VolatilityProfile.regime(candles),
          rsi: MomentumEngine.rsi(candles).compact.last&.round(1)
        }
      end

      {
        alignment: align,
        pullback_opportunities: pullbacks,
        per_timeframe: per_tf
      }
    end

    def self.classify_alignment(score)
      if score > 0.6 then :strong_bullish
      elsif score > 0.2 then :bullish
      elsif score < -0.6 then :strong_bearish
      elsif score < -0.2 then :bearish
      else :neutral
      end
    end
  end
end
