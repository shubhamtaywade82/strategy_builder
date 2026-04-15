# frozen_string_literal: true

module StrategyBuilder
  class Scorer
    # Composite scoring formula from the architecture spec.
    # Weights are tunable but defaults match the recommended formula.
    WEIGHTS = {
      expectancy: 0.25,
      profit_factor: 0.20,
      oos_stability: 0.15,
      drawdown_resilience: 0.15,
      session_consistency: 0.10,
      parameter_robustness: 0.10,
      trade_frequency: 0.05
    }.freeze

    # Score a strategy based on its walk-forward results.
    # Returns: { final_score: Float, component_scores: Hash, rank: nil }
    def self.score(walk_forward_result:, session_results: nil, robustness_result: nil)
      agg = walk_forward_result[:aggregate]

      components = {
        expectancy: normalize_expectancy(agg[:oos_expectancy]),
        profit_factor: normalize_profit_factor(agg[:oos_profit_factor]),
        oos_stability: walk_forward_result[:stability_score],
        drawdown_resilience: normalize_drawdown(agg[:oos_max_drawdown], agg[:oos_expectancy]),
        session_consistency: session_results ? score_session_consistency(session_results) : 0.5,
        parameter_robustness: robustness_result ? robustness_result[:robustness_score] : 0.5,
        trade_frequency: normalize_trade_frequency(agg[:oos_trade_count])
      }

      final = WEIGHTS.sum { |key, weight| components[key] * weight }

      { final_score: final.round(4), component_scores: components }
    end

    private_class_method def self.normalize_expectancy(exp)
      return 0.0 if exp.nil? || exp <= 0

      [exp / 0.5, 1.0].min # 0.5 expectancy = perfect score
    end

    private_class_method def self.normalize_profit_factor(pf)
      return 0.0 if pf.nil? || pf <= 1.0

      [(pf - 1.0) / 2.0, 1.0].min # PF 3.0 = perfect score
    end

    private_class_method def self.normalize_drawdown(max_dd, expectancy)
      return 0.0 if max_dd.nil? || expectancy.nil? || expectancy.zero?

      # Calmar-like: reward high return relative to drawdown.
      ratio = max_dd.zero? ? 10.0 : expectancy.abs / max_dd
      [ratio / 2.0, 1.0].min
    end

    private_class_method def self.normalize_trade_frequency(count)
      return 0.0 if count.nil? || count < 10

      # Sweet spot: 30-200 trades. Too few = unreliable. Too many = overtrading.
      if count < 30
        count / 30.0
      elsif count <= 200
        1.0
      else
        [200.0 / count, 0.5].max
      end
    end

    private_class_method def self.score_session_consistency(session_results)
      return 0.5 if session_results.nil? || session_results.empty?

      profitable_sessions = session_results.count { |_s, m| m[:expectancy] > 0 }
      total_sessions = session_results.size
      return 0.0 if total_sessions.zero?

      (profitable_sessions.to_f / total_sessions).round(4)
    end
  end

  class Gatekeeper
    # Hard gates that reject strategies regardless of score.
    # A strategy that fails any gate is rejected — no exceptions.
    GATES = {
      min_trades: 20,
      max_drawdown_multiple: 5.0,      # max DD / expectancy
      min_oos_positive_folds: 0.6,     # 60% of OOS folds must be positive
      min_profit_factor: 1.1,
      max_avg_degradation: 0.7,        # IS-to-OOS degradation
      min_win_rate: 0.25               # Floor to reject coin-flip noise
    }.freeze

    def self.evaluate(walk_forward_result:, metrics: nil)
      agg = walk_forward_result[:aggregate]
      failures = []

      if agg[:oos_trade_count] < GATES[:min_trades]
        failures << "Insufficient trades: #{agg[:oos_trade_count]} < #{GATES[:min_trades]}"
      end

      if agg[:oos_expectancy] <= 0
        failures << "Negative OOS expectancy: #{agg[:oos_expectancy]}"
      end

      if agg[:oos_profit_factor] < GATES[:min_profit_factor]
        failures << "Low profit factor: #{agg[:oos_profit_factor]} < #{GATES[:min_profit_factor]}"
      end

      if agg[:avg_degradation] > GATES[:max_avg_degradation]
        failures << "High IS-to-OOS degradation: #{agg[:avg_degradation]} > #{GATES[:max_avg_degradation]}"
      end

      if agg[:oos_win_rate] < GATES[:min_win_rate]
        failures << "Low win rate: #{agg[:oos_win_rate]} < #{GATES[:min_win_rate]}"
      end

      stability = walk_forward_result[:stability_score]
      if stability < GATES[:min_oos_positive_folds]
        failures << "Unstable across folds: stability #{stability} < #{GATES[:min_oos_positive_folds]}"
      end

      if agg[:oos_expectancy] > 0 && agg[:oos_max_drawdown] > 0
        dd_ratio = agg[:oos_max_drawdown] / agg[:oos_expectancy]
        if dd_ratio > GATES[:max_drawdown_multiple]
          failures << "Excessive drawdown ratio: #{dd_ratio.round(2)} > #{GATES[:max_drawdown_multiple]}"
        end
      end

      status = if failures.empty?
                 "pass"
               elsif failures.size <= 2
                 "watchlist"
               else
                 "reject"
               end

      { status: status, failures: failures, gate_count: GATES.size, failures_count: failures.size }
    end
  end

  class Robustness
    # Test parameter sensitivity by varying parameters within declared ranges.
    # A robust strategy should not collapse with small parameter changes.

    PERTURBATION_STEPS = 5

    def self.analyze(strategy:, candles:, engine:, signal_generator_factory:)
      ranges = strategy[:parameter_ranges] || {}
      return { robustness_score: 0.5, tested_params: 0 } if ranges.empty?

      results_per_param = {}

      ranges.each do |param_name, range_spec|
        next unless range_spec.is_a?(Array) && range_spec.size == 2

        low, high = range_spec
        next unless low.is_a?(Numeric) && high.is_a?(Numeric)

        step = (high - low) / PERTURBATION_STEPS.to_f
        param_results = []

        (0..PERTURBATION_STEPS).each do |i|
          value = low + (step * i)
          mutated = deep_merge_param(strategy, param_name, value)
          sg = signal_generator_factory.call(mutated)

          bt = engine.run(strategy: mutated, candles: candles, signal_generator: sg)
          param_results << { value: value, expectancy: bt[:metrics][:expectancy] }
        end

        results_per_param[param_name] = param_results
      end

      robustness_score = compute_robustness_score(results_per_param)

      {
        robustness_score: robustness_score,
        tested_params: results_per_param.size,
        param_sensitivity: results_per_param.transform_values { |r| summarize_sensitivity(r) }
      }
    end

    private_class_method def self.compute_robustness_score(results)
      return 0.5 if results.empty?

      scores = results.map do |_param, results_array|
        expectancies = results_array.map { |r| r[:expectancy] }
        positive_count = expectancies.count { |e| e > 0 }

        positive_count.to_f / expectancies.size
      end

      (scores.sum / scores.size).round(4)
    end

    private_class_method def self.summarize_sensitivity(results)
      expectancies = results.map { |r| r[:expectancy] }
      {
        min: expectancies.min,
        max: expectancies.max,
        mean: (expectancies.sum / expectancies.size.to_f).round(4),
        all_positive: expectancies.all? { |e| e > 0 },
        stable: (expectancies.max - expectancies.min).abs < expectancies.map(&:abs).max * 0.5
      }
    end

    private_class_method def self.deep_merge_param(strategy, param_name, value)
      # Clone strategy and set the parameter value.
      # Parameters can live in filters, risk, or exit config.
      mutated = Marshal.load(Marshal.dump(strategy))

      [:filters, :risk, :exit, :entry].each do |section|
        next unless mutated[section].is_a?(Hash)

        if mutated[section].key?(param_name.to_sym)
          mutated[section][param_name.to_sym] = value
          return mutated
        end
      end

      # If not found in sections, set in parameter_ranges for reference.
      mutated[:parameter_ranges] ||= {}
      mutated[:parameter_ranges][param_name] = value
      mutated
    end
  end
end
