# frozen_string_literal: true

module StrategyBuilder
  class MomentumEngine
    # Exponential Moving Average
    def self.ema(values, period:)
      return [] if values.size < period

      multiplier = 2.0 / (period + 1)
      result = [nil] * (period - 1)
      sma = values[0...period].sum / period.to_f
      result << sma

      values[period..].each do |val|
        prev = result.last
        result << (val - prev) * multiplier + prev
      end

      result
    end

    # Simple Moving Average
    def self.sma(values, period:)
      return [] if values.size < period

      result = [nil] * (period - 1)
      values.each_cons(period) do |window|
        result << window.sum / period.to_f
      end
      result
    end

    # RSI (Wilder's smoothing)
    def self.rsi(candles, period: 14)
      closes = candles.map { |c| c[:close] }
      return [nil] * candles.size if closes.size < period + 1

      changes = closes.each_cons(2).map { |a, b| b - a }

      gains = changes.map { |c| c > 0 ? c : 0 }
      losses = changes.map { |c| c < 0 ? c.abs : 0 }

      avg_gain = gains[0...period].sum / period.to_f
      avg_loss = losses[0...period].sum / period.to_f

      result = [nil] * (period + 1)

      if avg_loss.zero?
        result << 100.0
      else
        rs = avg_gain / avg_loss
        result << 100.0 - (100.0 / (1.0 + rs))
      end

      changes[period..].each_with_index do |_change, i|
        idx = period + i
        gain = gains[idx]
        loss = losses[idx]

        avg_gain = (avg_gain * (period - 1) + gain) / period.to_f
        avg_loss = (avg_loss * (period - 1) + loss) / period.to_f

        if avg_loss.zero?
          result << 100.0
        else
          rs = avg_gain / avg_loss
          result << 100.0 - (100.0 / (1.0 + rs))
        end
      end

      # Pad front to match candle size
      result[0...candles.size]
    end

    # MACD (12, 26, 9 default)
    def self.macd(candles, fast: 12, slow: 26, signal: 9)
      closes = candles.map { |c| c[:close] }
      fast_ema = ema(closes, period: fast)
      slow_ema = ema(closes, period: slow)

      macd_line = fast_ema.zip(slow_ema).map do |f, s|
        (f && s) ? f - s : nil
      end

      compact_macd = macd_line.compact
      signal_line_raw = ema(compact_macd, period: signal)

      # Realign signal line to full array
      offset = macd_line.index { |v| !v.nil? }
      signal_line = [nil] * (offset + signal - 1) + signal_line_raw.compact
      signal_line += [nil] * (candles.size - signal_line.size) if signal_line.size < candles.size

      histogram = macd_line.each_with_index.map do |m, i|
        s = signal_line[i]
        (m && s) ? m - s : nil
      end

      { macd: macd_line, signal: signal_line[0...candles.size], histogram: histogram }
    end

    # Rate of Change
    def self.roc(candles, period: 10)
      closes = candles.map { |c| c[:close] }
      result = [nil] * period

      closes.each_cons(period + 1) do |window|
        prev = window.first
        curr = window.last
        result << (prev.zero? ? 0.0 : ((curr - prev) / prev) * 100.0)
      end

      result[0...candles.size]
    end

    # EMA slope: direction and magnitude of EMA change.
    def self.ema_slope(candles, period: 20, slope_lookback: 3)
      closes = candles.map { |c| c[:close] }
      ema_vals = ema(closes, period: period)

      ema_vals.each_cons(slope_lookback + 1).map do |window|
        if window.all?
          (window.last - window.first) / window.first * 100.0
        end
      end
      result = [nil] * (period + slope_lookback - 1)
      ema_vals.compact.each_cons(slope_lookback + 1) do |window|
        result << (window.last - window.first) / window.first * 100.0
      end
      result[0...candles.size]
    end

    # Full momentum profile.
    def self.profile(candles)
      rsi_vals = rsi(candles)
      macd_data = macd(candles)

      {
        rsi_current: rsi_vals.compact.last,
        rsi_zone: classify_rsi(rsi_vals.compact.last),
        macd_histogram: macd_data[:histogram].compact.last,
        macd_crossover: detect_macd_crossover(macd_data),
        roc_10: roc(candles, period: 10).compact.last,
        ema_20_slope: ema_slope(candles, period: 20).compact.last,
        ema_50_slope: ema_slope(candles, period: 50).compact.last
      }
    end

    def self.classify_rsi(value)
      return :unknown if value.nil?

      if value >= 70 then :overbought
      elsif value <= 30 then :oversold
      elsif value >= 60 then :bullish
      elsif value <= 40 then :bearish
      else :neutral
      end
    end

    def self.detect_macd_crossover(macd_data)
      hist = macd_data[:histogram].compact
      return :none if hist.size < 2

      if hist[-2] < 0 && hist[-1] >= 0
        :bullish_crossover
      elsif hist[-2] > 0 && hist[-1] <= 0
        :bearish_crossover
      else
        :none
      end
    end
  end
end
