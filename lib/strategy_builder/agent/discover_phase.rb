# frozen_string_literal: true

module StrategyBuilder
  module Agent
    # Feature discovery across instruments (parallel network I/O).
    class DiscoverPhase
      def initialize(logger:, candle_loader_factory:, parallel_max:)
        @logger = logger
        @candle_loader_factory = candle_loader_factory
        @parallel_max = parallel_max
      end

      def execute(instruments:, timeframes:, days_back:, memory:)
        from = Time.now - (days_back * 86_400)
        rows = ParallelInstrumentRunner.map_parallel(
          instruments,
          max_parallel: @parallel_max
        ) do |instrument|
          @logger.info { "Discovering features for #{instrument}..." }
          loader = @candle_loader_factory.call
          mtf = loader.fetch_mtf(instrument: instrument, timeframes: timeframes, from: from)
          features = FeatureBuilder.build(instrument: instrument, mtf_candles: mtf)
          [instrument, features]
        end

        results = rows.to_h
        results.each do |instrument, features|
          memory << { phase: :discover, instrument: instrument, features: features }
        end
        results
      end
    end
  end
end
