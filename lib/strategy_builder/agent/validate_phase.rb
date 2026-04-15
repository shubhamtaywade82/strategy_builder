# frozen_string_literal: true

module StrategyBuilder
  module Agent
    # Walk-forward validation across proposed strategies × instruments (parallel compute, sequential catalog writes).
    class ValidatePhase
      def initialize(
        logger:,
        candle_loader_factory:,
        backtest_engine_factory:,
        walk_forward_factory:,
        parallel_max:
      )
        @logger = logger
        @candle_loader_factory = candle_loader_factory
        @backtest_engine_factory = backtest_engine_factory
        @walk_forward_factory = walk_forward_factory
        @parallel_max = parallel_max
      end

      def execute(catalog:, instruments:, days_back:, memory:)
        proposed = catalog.by_status("proposed")
        @logger.info { "Validating #{proposed.size} proposed strategies..." }
        return if proposed.empty?

        from = Time.now - (days_back * 86_400)
        jobs = proposed.product(instruments)

        rows = ParallelInstrumentRunner.map_parallel(jobs, max_parallel: @parallel_max) do |pair|
          entry, instrument = pair
          run_job(entry: entry, instrument: instrument, from: from)
        end

        rows.compact.each do |row|
          catalog.attach_backtest(row[:id], row[:payload])
          memory << row[:memory]
        end
      end

      private

      def run_job(entry:, instrument:, from:)
        strategy = entry[:strategy]
        @logger.info { "Backtesting #{strategy[:name]} on #{instrument}..." }

        signal_gen = SignalGeneratorFactory.build(strategy)
        loader = @candle_loader_factory.call
        primary_tf = strategy[:timeframes]&.last || "5m"
        candles = loader.fetch(instrument: instrument, timeframe: primary_tf, from: from)
        return nil if candles.size < 200

        engine = @backtest_engine_factory.call
        walk_forward = @walk_forward_factory.call(engine)
        wf_result = walk_forward.run(
          strategy: strategy,
          candles: candles,
          signal_generator: signal_gen
        )

        {
          id: entry[:id],
          payload: {
            metrics: wf_result[:aggregate],
            walk_forward: wf_result,
            instrument: instrument,
            candle_count: candles.size
          },
          memory: { phase: :validate, strategy_id: entry[:id], instrument: instrument, result: wf_result[:aggregate] }
        }
      end
    end
  end
end
