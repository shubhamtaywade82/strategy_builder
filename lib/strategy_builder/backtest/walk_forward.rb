# frozen_string_literal: true

module StrategyBuilder
  class WalkForward
    # Walk-forward analysis: split data into folds, backtest on in-sample,
    # validate on out-of-sample, aggregate results.
    # This is the only credible way to evaluate strategy performance.

    DEFAULT_FOLDS = 5

    def initialize(engine: BacktestEngine.new)
      @engine = engine
      @logger = StrategyBuilder.logger
      @in_sample_ratio = StrategyBuilder.configuration.walk_forward_in_sample_ratio
    end

    # Run walk-forward analysis using non-overlapping contiguous folds (each fold is its own IS/OOS split).
    # Returns: { folds: [...], aggregate: {...}, stability_score: Float }
    def run(strategy:, candles:, signal_generator:, folds: DEFAULT_FOLDS)
      fold_size = candles.size / folds
      raise BacktestError, "Insufficient data for #{folds} folds (#{candles.size} candles)" if fold_size < 100

      fold_results = []

      folds.times do |i|
        fold_start = i * fold_size
        fold_end = [(i + 1) * fold_size - 1, candles.size - 1].min

        fold_candles = candles[fold_start..fold_end]
        split_idx = (fold_candles.size * @in_sample_ratio).to_i

        in_sample = fold_candles[0...split_idx]
        out_of_sample = fold_candles[split_idx..]

        @logger.info { "Fold #{i + 1}/#{folds}: IS=#{in_sample.size} OOS=#{out_of_sample.size} candles" }

        is_result = @engine.run(
          strategy: strategy,
          candles: in_sample,
          signal_generator: signal_generator
        )

        oos_result = @engine.run(
          strategy: strategy,
          candles: out_of_sample,
          signal_generator: signal_generator
        )

        fold_results << {
          fold: i + 1,
          in_sample: is_result[:metrics],
          out_of_sample: oos_result[:metrics],
          is_trade_count: is_result[:trades].size,
          oos_trade_count: oos_result[:trades].size,
          degradation: compute_degradation(is_result[:metrics], oos_result[:metrics])
        }
      end

      aggregate = aggregate_folds(fold_results)
      stability = compute_stability(fold_results)

      {
        folds: fold_results,
        aggregate: aggregate,
        stability_score: stability,
        passes_walk_forward: stability > 0.5 && aggregate[:oos_expectancy] > 0
      }
    end

    # Run session-wise analysis: same strategy tested per session.
    def session_analysis(strategy:, candles:, signal_generator:)
      session_groups = SessionDetector.group_by_session(candles)

      session_groups.each_with_object({}) do |(session, session_candles), result|
        next if session_candles.size < 100

        bt = @engine.run(
          strategy: strategy,
          candles: session_candles,
          signal_generator: signal_generator
        )

        result[session] = bt[:metrics]
      end
    end

    private

    def compute_degradation(is_metrics, oos_metrics)
      return 1.0 if is_metrics[:expectancy].zero?

      oos_exp = oos_metrics[:expectancy]
      is_exp = is_metrics[:expectancy]

      # Positive degradation = OOS worse than IS (expected).
      # Negative degradation = OOS better than IS (suspicious or lucky).
      1.0 - (oos_exp / is_exp)
    rescue ZeroDivisionError
      1.0
    end

    def aggregate_folds(folds)
      oos_metrics = folds.map { |f| f[:out_of_sample] }
      is_metrics = folds.map { |f| f[:in_sample] }

      {
        oos_expectancy: safe_mean(oos_metrics.map { |m| m[:expectancy] }),
        oos_win_rate: safe_mean(oos_metrics.map { |m| m[:win_rate] }),
        oos_profit_factor: safe_mean(oos_metrics.map { |m| m[:profit_factor] }),
        oos_max_drawdown: oos_metrics.map { |m| m[:max_drawdown] }.max || 0.0,
        oos_avg_r: safe_mean(oos_metrics.map { |m| m[:avg_r] }),
        oos_trade_count: oos_metrics.sum { |m| m[:trade_count] },
        is_expectancy: safe_mean(is_metrics.map { |m| m[:expectancy] }),
        is_profit_factor: safe_mean(is_metrics.map { |m| m[:profit_factor] }),
        avg_degradation: safe_mean(folds.map { |f| f[:degradation] })
      }
    end

    def compute_stability(folds)
      oos_expectancies = folds.map { |f| f[:out_of_sample][:expectancy] }
      return 0.0 if oos_expectancies.empty?

      # Stability = fraction of folds with positive OOS expectancy.
      positive_folds = oos_expectancies.count { |e| e > 0 }
      base_stability = positive_folds.to_f / oos_expectancies.size

      # Penalize high variance across folds.
      mean = oos_expectancies.sum / oos_expectancies.size.to_f
      variance = oos_expectancies.sum { |e| (e - mean)**2 } / oos_expectancies.size.to_f
      cv = mean.zero? ? Float::INFINITY : Math.sqrt(variance) / mean.abs

      # High CV means unstable — reduce score.
      stability_penalty = [cv / 2.0, 0.5].min
      [base_stability - stability_penalty, 0.0].max.round(4)
    end

    def safe_mean(values)
      return 0.0 if values.nil? || values.empty?

      (values.sum / values.size.to_f).round(4)
    end
  end
end
