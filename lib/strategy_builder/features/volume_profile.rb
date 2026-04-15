# frozen_string_literal: true

module StrategyBuilder
  class VolumeProfile
    DEFAULT_LOOKBACK = 20

    # Relative volume at bar i: volumes[i] / mean(volumes[i-lookback...i-1]).
    # Indices 0..lookback-1 are nil (aligned with candle index i).
    def self.relative_volume(candles, lookback: DEFAULT_LOOKBACK)
      return [] if candles.nil? || candles.empty?

      volumes = candles.map { |c| c[:volume] }
      candles.size.times.map do |i|
        next nil if i < lookback

        baseline = volumes[(i - lookback)...i]
        avg = baseline.sum / lookback.to_f
        avg.zero? ? 0.0 : volumes[i] / avg
      end
    end

    # Z-score of current volume vs trailing window *excluding* the current bar.
    # One value per candle index; last bar has a score (fixes prior off-by-one short array).
    def self.volume_zscore(candles, lookback: DEFAULT_LOOKBACK)
      return [] if candles.nil? || candles.empty?

      volumes = candles.map { |c| c[:volume] }
      candles.size.times.map do |i|
        next nil if i < lookback

        window = volumes[(i - lookback)...i]
        mean = window.sum / lookback.to_f
        variance = window.sum { |v| (v - mean)**2 } / lookback.to_f
        stddev = Math.sqrt(variance)

        if stddev.zero?
          0.0
        else
          (volumes[i] - mean) / stddev
        end
      end
    end

    # Detect volume bursts: candles where volume z-score exceeds threshold.
    def self.burst_detection(candles, lookback: DEFAULT_LOOKBACK, threshold: 2.0)
      zscores = volume_zscore(candles, lookback: lookback)

      candles.each_with_index.filter_map do |candle, i|
        next if zscores[i].nil? || zscores[i] < threshold

        {
          index: i,
          timestamp: candle[:timestamp],
          volume: candle[:volume],
          zscore: zscores[i],
          direction: candle[:close] >= candle[:open] ? :bullish : :bearish
        }
      end
    end

    # Volume-weighted average price (VWAP) for a session.
    def self.vwap(candles)
      cumulative_tp_vol = 0.0
      cumulative_vol = 0.0

      candles.map do |c|
        typical_price = (c[:high] + c[:low] + c[:close]) / 3.0
        cumulative_tp_vol += typical_price * c[:volume]
        cumulative_vol += c[:volume]
        cumulative_vol.zero? ? typical_price : cumulative_tp_vol / cumulative_vol
      end
    end

    # Full volume profile.
    def self.profile(candles, lookback: DEFAULT_LOOKBACK)
      rvol = relative_volume(candles, lookback: lookback)
      zscores = volume_zscore(candles, lookback: lookback)
      bursts = burst_detection(candles, lookback: lookback)

      {
        relative_volume_current: rvol.compact.last,
        volume_zscore_current: zscores.compact.last,
        recent_bursts: bursts.last(5),
        burst_count_last_20: bursts.count { |b| b[:index] >= candles.size - 20 },
        vwap_current: vwap(candles).last
      }
    end
  end
end
