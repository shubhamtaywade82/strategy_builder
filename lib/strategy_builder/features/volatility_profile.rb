# frozen_string_literal: true

module StrategyBuilder
  class VolatilityProfile
    DEFAULT_ATR_PERIOD = 14
    COMPRESSION_THRESHOLD = 0.6  # ATR < 60% of rolling mean = compression
    EXPANSION_THRESHOLD = 1.5    # ATR > 150% of rolling mean = expansion

    # Compute ATR series for candles.
    # Returns Array with length candles.size; indices 0..period-1 are nil (warmup).
    def self.atr(candles, period: DEFAULT_ATR_PERIOD)
      return [] if candles.size < 2

      true_ranges = candles.each_cons(2).map do |prev, curr|
        [
          curr[:high] - curr[:low],
          (curr[:high] - prev[:close]).abs,
          (curr[:low] - prev[:close]).abs
        ].max
      end

      atr_values = [nil] * period
      first_atr = true_ranges[0...period].sum / period.to_f
      atr_values << first_atr

      true_ranges[period..].each do |tr|
        prev_atr = atr_values.last
        new_atr = (prev_atr * (period - 1) + tr) / period.to_f
        atr_values << new_atr
      end

      atr_values
    end

    # ATR as percentage of price.
    def self.atr_percent(candles, period: DEFAULT_ATR_PERIOD)
      atr_vals = atr(candles, period: period)
      candles.each_with_index.map do |c, i|
        next nil if atr_vals[i].nil? || c[:close].zero?

        (atr_vals[i] / c[:close]) * 100.0
      end
    end

    # Range expansion ratio: current range / ATR.
    def self.range_expansion(candles, period: DEFAULT_ATR_PERIOD)
      atr_vals = atr(candles, period: period)
      candles.each_with_index.map do |c, i|
        next nil if atr_vals[i].nil? || atr_vals[i].zero?

        (c[:high] - c[:low]) / atr_vals[i]
      end
    end

    # Detect volatility regime: :compression, :normal, :expansion
    def self.regime(candles, period: DEFAULT_ATR_PERIOD, lookback: 50)
      atr_vals = atr(candles, period: period).compact
      return :unknown if atr_vals.size < lookback

      current_atr = atr_vals.last
      rolling_mean = atr_vals.last(lookback).sum / lookback.to_f

      ratio = current_atr / rolling_mean
      if ratio < COMPRESSION_THRESHOLD
        :compression
      elsif ratio > EXPANSION_THRESHOLD
        :expansion
      else
        :normal
      end
    end

    # Full volatility profile for the candle set.
    def self.profile(candles, period: DEFAULT_ATR_PERIOD)
      atr_vals = atr(candles, period: period)
      atr_pct = atr_percent(candles, period: period)

      current_atr = atr_vals.compact.last
      current_atr_pct = atr_pct.compact.last

      {
        current_atr: current_atr,
        current_atr_percent: current_atr_pct,
        regime: regime(candles, period: period),
        range_expansion_last: range_expansion(candles, period: period).compact.last,
        atr_series_size: atr_vals.compact.size
      }
    end
  end
end
