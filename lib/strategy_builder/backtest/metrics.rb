# frozen_string_literal: true

module StrategyBuilder
  class Metrics
    # Compute comprehensive metrics from a list of Trade objects.
    # Returns a flat hash suitable for ranking and documentation.
    def self.compute(trades)
      return empty_metrics if trades.nil? || trades.empty?

      pnls = trades.map(&:pnl)
      r_multiples = trades.map(&:pnl_r).compact
      winners = trades.select { |t| t.pnl.positive? }
      losers = trades.select { |t| t.pnl <= 0 }

      {
        trade_count: trades.size,
        net_pnl: pnls.sum.round(4),
        gross_profit: winners.sum(&:pnl).round(4),
        gross_loss: losers.sum(&:pnl).round(4),
        win_rate: (winners.size.to_f / trades.size).round(4),
        loss_rate: (losers.size.to_f / trades.size).round(4),
        avg_win: winners.any? ? (winners.sum(&:pnl) / winners.size).round(4) : 0.0,
        avg_loss: losers.any? ? (losers.sum(&:pnl) / losers.size).round(4) : 0.0,
        profit_factor: compute_profit_factor(winners, losers),
        expectancy: compute_expectancy(trades),
        avg_r: r_multiples.any? ? (r_multiples.sum / r_multiples.size).round(4) : 0.0,
        max_r: r_multiples.max || 0.0,
        min_r: r_multiples.min || 0.0,
        max_drawdown: compute_max_drawdown(pnls),
        max_consecutive_losses: max_consecutive(losers, trades),
        max_consecutive_wins: max_consecutive(winners, trades),
        avg_hold_candles: (trades.sum(&:hold_candles).to_f / trades.size).round(1),
        total_fees: trades.sum(&:fees).round(4),
        sharpe_ratio: compute_sharpe(pnls),
        sortino_ratio: compute_sortino(pnls),
        calmar_ratio: compute_calmar(pnls),
        exit_reason_distribution: exit_reason_dist(trades),
        direction_distribution: direction_dist(trades),
        session_performance: {},   # populated by walk_forward with session tags
        regime_performance: {},    # populated externally
        instrument_performance: {} # populated externally
      }
    end

    def self.empty_metrics
      {
        trade_count: 0, net_pnl: 0.0, gross_profit: 0.0, gross_loss: 0.0,
        win_rate: 0.0, loss_rate: 0.0, avg_win: 0.0, avg_loss: 0.0,
        profit_factor: 0.0, expectancy: 0.0, avg_r: 0.0, max_r: 0.0, min_r: 0.0,
        max_drawdown: 0.0, max_consecutive_losses: 0, max_consecutive_wins: 0,
        avg_hold_candles: 0.0, total_fees: 0.0, sharpe_ratio: 0.0,
        sortino_ratio: 0.0, calmar_ratio: 0.0,
        exit_reason_distribution: {}, direction_distribution: {},
        session_performance: {}, regime_performance: {}, instrument_performance: {}
      }
    end

    def self.compute_profit_factor(winners, losers)
      gross_profit = winners.sum(&:pnl)
      gross_loss = losers.sum(&:pnl).abs
      return 0.0 if gross_loss.zero?

      (gross_profit / gross_loss).round(4)
    end

    def self.compute_expectancy(trades)
      return 0.0 if trades.empty?

      (trades.sum(&:pnl) / trades.size).round(4)
    end

    def self.compute_max_drawdown(pnls)
      return 0.0 if pnls.empty?

      cumulative = 0.0
      peak = 0.0
      max_dd = 0.0

      pnls.each do |pnl|
        cumulative += pnl
        peak = cumulative if cumulative > peak
        dd = peak - cumulative
        max_dd = dd if dd > max_dd
      end

      max_dd.round(4)
    end

    def self.max_consecutive(subset, all_trades)
      return 0 if subset.empty?

      subset_ids = subset.map(&:position_id).to_set
      max_streak = 0
      current_streak = 0

      all_trades.each do |t|
        if subset_ids.include?(t.position_id)
          current_streak += 1
          max_streak = current_streak if current_streak > max_streak
        else
          current_streak = 0
        end
      end

      max_streak
    end

    def self.compute_sharpe(pnls, risk_free: 0.0)
      return 0.0 if pnls.size < 2

      mean = pnls.sum / pnls.size.to_f
      variance = pnls.sum { |p| (p - mean)**2 } / (pnls.size - 1).to_f
      stddev = Math.sqrt(variance)
      return 0.0 if stddev.zero?

      ((mean - risk_free) / stddev).round(4)
    end

    def self.compute_sortino(pnls, risk_free: 0.0)
      return 0.0 if pnls.size < 2

      mean = pnls.sum / pnls.size.to_f
      downside = pnls.select { |p| p < risk_free }
      return 0.0 if downside.empty?

      downside_variance = downside.sum { |p| (p - risk_free)**2 } / downside.size.to_f
      downside_dev = Math.sqrt(downside_variance)
      return 0.0 if downside_dev.zero?

      ((mean - risk_free) / downside_dev).round(4)
    end

    def self.compute_calmar(pnls)
      return 0.0 if pnls.empty?

      total_return = pnls.sum
      max_dd = compute_max_drawdown(pnls)
      return 0.0 if max_dd.zero?

      (total_return / max_dd).round(4)
    end

    def self.exit_reason_dist(trades)
      trades.group_by(&:exit_reason).transform_values(&:size)
    end

    def self.direction_dist(trades)
      trades.group_by(&:direction).transform_values(&:size)
    end
  end
end
