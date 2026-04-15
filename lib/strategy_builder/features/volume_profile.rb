# frozen_string_literal: true

module StrategyBuilder
  class VolumeProfile
    DEFAULT_LOOKBACK = 20

    # Relative volume: current volume / rolling average volume.
    def self.relative_volume(candles, lookback: DEFAULT_LOOKBACK)
      return [nil] * candles.size if candles.size < lookback

      volumes = candles.map { |c| c[:volume] }
      result = [nil] * (lookback - 1)

      volumes.each_cons(lookback + 1) do |window|
        baseline = window[0...-1]
        current = window.last
        avg = baseline.sum / baseline.size.to_f
        result << (avg.zero? ? 0.0 : current / avg)
      end

      # Handle last element alignment
      if result.size < candles.size
        avg = volumes.last(lookback + 1)[0...-1].sum / lookback.to_f
        result << (avg.zero? ? 0.0 : volumes.last / avg)
      end

      result[0...candles.size]
    end

    # Volume z-score: how many standard deviations current volume is from mean.
    def self.volume_zscore(candles, lookback: DEFAULT_LOOKBACK)
      return [nil] * candles.size if candles.size < lookback

      volumes = candles.map { |c| c[:volume] }
      result = [nil] * (lookback - 1)

      (lookback...volumes.size).each do |i|
        window = volumes[(i - lookback)...i]
        mean = window.sum / window.size.to_f
        variance = window.sum { |v| (v - mean)**2 } / window.size.to_f
        stddev = Math.sqrt(variance)

        if stddev.zero?
          result << 0.0
        else
          result << (volumes[i] - mean) / stddev
        end
      end

      result[0...candles.size]
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
