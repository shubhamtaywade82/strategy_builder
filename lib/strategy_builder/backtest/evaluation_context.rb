# frozen_string_literal: true

module StrategyBuilder
  # Lightweight context for evaluating conditions on a specific candle slice.
  # Memoizes heavy computations so multiple conditions share the same indicator states.
  class EvaluationContext
    attr_reader :candles, :strategy, :index, :current_candle, :previous_candle, :mtf_candles
    attr_accessor :direction, :entry_price, :stop_distance, :size

    def initialize(candles, strategy, mtf_candles: nil)
      @candles = candles
      @strategy = strategy
      @mtf_candles = mtf_candles
      @index = candles.size - 1
      @current_candle = candles.last
      @previous_candle = candles[-2]

      @direction = nil
      @entry_price = nil
      @stop_distance = nil
      @size = 1.0

      @memo = {}
    end

    def atr
      @memo[:atr] ||= VolatilityProfile.atr(candles).compact.last || 0.0
    end

    def rsi
      @memo[:rsi] ||= MomentumEngine.rsi(candles).compact.last
    end

    def vwap
      @memo[:vwap] ||= VolumeProfile.vwap(candles)
    end

    def swing_points
      @memo[:swing_points] ||= StructureDetector.swing_points(candles.last(100))
    end

    def structure
      @memo[:structure] ||= StructureDetector.structure(candles)
    end

    # Structure on the declared higher timeframe (first in strategy[:timeframes]) when MTF data is supplied;
    # otherwise same as +structure+ on the execution series.
    def higher_tf_structure
      @memo[:higher_tf_structure] ||= compute_higher_tf_structure
    end

    def regime
      @memo[:regime] ||= VolatilityProfile.regime(candles)
    end

    def volume_zscore
      @memo[:volume_zscore] ||= VolumeProfile.volume_zscore(candles).compact.last || 0.0
    end

    def ema(period: 20)
      @memo[:"ema_#{period}"] ||= MomentumEngine.ema(candles.map { |c| c[:close] }, period: period).compact
    end

    private

    def compute_higher_tf_structure
      tfs = strategy[:timeframes]
      return StructureDetector.structure(candles) unless tfs.is_a?(Array) && tfs.size >= 2 && @mtf_candles.is_a?(Hash)

      htf = tfs.first
      series = mtf_series_up_to(htf)
      return :unknown if series.size < 25

      StructureDetector.structure(series)
    end

    def mtf_series_up_to(timeframe)
      rows = @mtf_candles[timeframe]
      return [] unless rows.is_a?(Array) && !rows.empty?

      tmax = candle_ts(@current_candle)
      rows.select { |c| candle_ts(c) <= tmax }
    end

    def candle_ts(candle)
      ts = candle[:timestamp]
      ts.is_a?(Time) ? ts.to_i : ts.to_i
    end
  end
end
