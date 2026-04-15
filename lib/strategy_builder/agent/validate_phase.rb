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

        loader = @candle_loader_factory.call
        tf = strategy[:timeframes]
        timeframes = (tf.is_a?(Array) && !tf.empty?) ? tf : StrategyBuilder.configuration.default_timeframes
        primary_tf = timeframes.last || "5m"
        mtf = loader.fetch_mtf(instrument: instrument, timeframes: timeframes, from: from)
        candles = mtf[primary_tf] || []
        return nil if candles.size < 200

        signal_gen = SignalEvaluator.build(strategy, mtf_candles: mtf)

        engine = @backtest_engine_factory.call
        walk_forward = @walk_forward_factory.call(engine)
        wf_result = walk_forward.run(
          strategy: strategy,
          candles: candles,
          signal_generator: signal_gen,
          mtf_candles: mtf
        )

        wf_result[:regime_slices] = walk_forward.volatility_regime_slices(
          strategy: strategy,
          candles: candles,
          signal_generator: signal_gen,
          mtf_candles: mtf
        )
        wf_result[:anchored_holdout] = walk_forward.anchored_holdout(
          strategy: strategy,
          candles: candles,
          signal_generator: signal_gen,
          mtf_candles: mtf
        )

        session_results = walk_forward.session_analysis(
          strategy: strategy,
          candles: candles,
          signal_generator: signal_gen,
          mtf_candles: mtf
        )

        robustness_result = StrategyBuilder::Robustness.analyze(
          strategy: strategy,
          candles: candles,
          engine: engine,
          mtf_candles: mtf,
          signal_generator_factory: lambda { |mutated|
            SignalEvaluator.build(mutated, mtf_candles: mtf)
          }
        )

        {
          id: entry[:id],
          payload: {
            metrics: wf_result[:aggregate],
            walk_forward: wf_result,
            session_results: session_results,
            robustness_result: robustness_result,
            instrument: instrument,
            candle_count: candles.size
          },
          memory: { phase: :validate, strategy_id: entry[:id], instrument: instrument, result: wf_result[:aggregate] }
        }
      end
    end
  end
end
