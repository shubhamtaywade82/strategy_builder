# frozen_string_literal: true

module StrategyBuilder
  class DataNormalizer
    # Normalize raw candle data into the internal shape used by the feature engine.
    # Input: Hash of { timeframe => Array<candle_hash> }
    # Output: Normalized dataset hash
    def self.normalize(instrument:, mtf_candles:, sessions: nil)
      sessions ||= SessionDetector.detect_sessions(mtf_candles.values.first || [])

      {
        instrument: instrument,
        timeframes: mtf_candles.keys,
        candles: mtf_candles,
        sessions: sessions,
        fetched_at: Time.now.to_i,
        candle_counts: mtf_candles.transform_values(&:size)
      }
    end
  end

  class CandleStore
    # In-memory candle cache keyed by instrument + timeframe.
    # Production replacement: PostgreSQL timeseries or TimescaleDB.

    def initialize
      @store = {}
    end

    def key(instrument, timeframe)
      "#{instrument}:#{timeframe}"
    end

    def put(instrument, timeframe, candles)
      k = key(instrument, timeframe)
      existing = @store[k] || []
      merged = (existing + candles).uniq { |c| c[:timestamp] }.sort_by { |c| c[:timestamp] }
      @store[k] = merged
    end

    def get(instrument, timeframe, from: nil, to: nil)
      k = key(instrument, timeframe)
      candles = @store[k] || []
      candles = candles.select { |c| c[:timestamp] >= from } if from
      candles = candles.select { |c| c[:timestamp] <= to } if to
      candles
    end

    def instruments
      @store.keys.map { |k| k.split(":").first }.uniq
    end

    def size
      @store.values.sum(&:size)
    end

    def clear!
      @store.clear
    end
  end
end
