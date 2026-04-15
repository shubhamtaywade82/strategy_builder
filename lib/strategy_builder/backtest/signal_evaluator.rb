# frozen_string_literal: true

module StrategyBuilder
  class SignalEvaluator
    def self.warmup_bars
      StrategyBuilder.configuration.backtest_indicator_warmup
    end

    def self.build(strategy, mtf_candles: nil)
      conditions = strategy.dig(:entry, :conditions) || []
      if conditions.empty?
        conditions = ['generic_breakout']
      else
        ConditionRegistry.validate_condition_names!(conditions)
      end

      filters = strategy[:filters] || {}
      sessions = strategy[:session] || []

      lambda do |candles, _strat, runtime_mtf = nil|
        return nil if candles.size < SignalEvaluator.warmup_bars

        mtf = runtime_mtf || mtf_candles
        ctx = EvaluationContext.new(candles, strategy, mtf_candles: mtf)

        passed = conditions.all? do |cond|
          ConditionRegistry.evaluate(cond, ctx)
        end

        next nil unless passed
        next nil unless ctx.direction && ctx.entry_price && ctx.stop_distance

        next nil unless passes_filters?(ctx, filters)
        next nil unless passes_session_filter?(ctx.current_candle, sessions)

        {
          direction: ctx.direction,
          entry_price: ctx.entry_price,
          stop_distance: ctx.stop_distance,
          size: ctx.size
        }
      end
    end

    def self.passes_filters?(ctx, filters)
      return false if filters[:min_volume_zscore] && (ctx.volume_zscore < filters[:min_volume_zscore])

      if filters[:min_atr_percent]
        atr_pct = VolatilityProfile.atr_percent(ctx.candles).compact.last
        return false if atr_pct && atr_pct < filters[:min_atr_percent]
      end

      if filters[:max_atr_percent]
        atr_pct = VolatilityProfile.atr_percent(ctx.candles).compact.last
        return false if atr_pct && atr_pct > filters[:max_atr_percent]
      end

      if filters[:required_regime]
        allowed = filters[:required_regime].map { |r| r.is_a?(String) ? r.to_sym : r }
        return false unless allowed.include?(ctx.regime)
      end

      if filters[:required_structure]
        allowed = filters[:required_structure].map { |s| s.is_a?(String) ? s.to_sym : s }
        return false unless allowed.include?(ctx.structure)
      end

      true
    end

    def self.passes_session_filter?(candle, sessions)
      return true if sessions.nil? || sessions.empty? || sessions.include?('any')

      tagged = SessionDetector.tag_candles([candle]).first
      candle_sessions = tagged[:sessions]

      sessions.any? { |s| candle_sessions.include?(s) }
    end
  end
end
