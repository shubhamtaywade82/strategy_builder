# frozen_string_literal: true

module StrategyBuilder
  class FeatureBuilder
    # Build the complete feature set for an instrument across all timeframes.
    # This is the single payload the LLM receives — it never computes features itself.
    def self.build(instrument:, mtf_candles:)
      raise DataError, "No candle data for #{instrument}" if mtf_candles.nil? || mtf_candles.empty?

      primary_tf = select_primary_timeframe(mtf_candles)
      primary_candles = mtf_candles[primary_tf]

      {
        instrument: instrument,
        computed_at: Time.now.utc.iso8601,
        primary_timeframe: primary_tf,
        candle_counts: mtf_candles.transform_values(&:size),
        mtf_alignment: MtfStack.profile(mtf_candles),
        sessions: SessionDetector.detect_sessions(primary_candles),
        session_ranges: build_session_ranges(primary_candles),
        volatility: VolatilityProfile.profile(primary_candles),
        structure: StructureDetector.profile(primary_candles),
        volume: VolumeProfile.profile(primary_candles),
        momentum: MomentumEngine.profile(primary_candles),
        per_timeframe_summary: build_per_tf_summary(mtf_candles)
      }
    end

    # Build features for a specific candle window (for backtesting).
    # Uses only data available up to `up_to_index` to prevent look-ahead bias.
    def self.build_at(instrument:, mtf_candles:, primary_tf:, up_to_index:)
      candles = mtf_candles[primary_tf][0..up_to_index]
      truncated_mtf = mtf_candles.transform_values do |tf_candles|
        last_ts = candles.last[:timestamp]
        tf_candles.select { |c| c[:timestamp] <= last_ts }
      end

      build(instrument: instrument, mtf_candles: truncated_mtf)
    end

    private_class_method def self.select_primary_timeframe(mtf_candles)
      # Prefer 5m as primary; fall back to whatever has most data.
      return "5m" if mtf_candles.key?("5m") && mtf_candles["5m"].size > 100

      mtf_candles.max_by { |_tf, candles| candles.size }.first
    end

    private_class_method def self.build_session_ranges(candles)
      return {} if candles.empty?

      # Get unique dates from candles
      dates = candles.map { |c|
        ts = c[:timestamp].is_a?(Time) ? c[:timestamp] : Time.at(c[:timestamp]).utc
        Date.new(ts.year, ts.month, ts.day)
      }.uniq.last(5) # last 5 days

      ranges = {}
      dates.each do |date|
        %w[asia london new_york].each do |session|
          range = SessionDetector.session_range(candles, session: session, date: date)
          ranges["#{date}_#{session}"] = range if range
        end
      end
      ranges
    end

    private_class_method def self.build_per_tf_summary(mtf_candles)
      mtf_candles.transform_values do |candles|
        next { insufficient_data: true } if candles.size < 30

        {
          trend: MtfStack.trend_direction(candles),
          structure: StructureDetector.structure(candles),
          volatility_regime: VolatilityProfile.regime(candles),
          rsi: MomentumEngine.rsi(candles).compact.last&.round(1),
          relative_volume: VolumeProfile.relative_volume(candles).compact.last&.round(2),
          atr_percent: VolatilityProfile.atr_percent(candles).compact.last&.round(3),
          candle_count: candles.size
        }
      end
    end
  end
end
