# frozen_string_literal: true

module StrategyBuilder
  class ConditionRegistry
    @registry = {}

    def self.register(name, &block)
      @registry[name.to_s] = block
    end

    def self.evaluate(condition_name, context)
      evaluator = @registry[condition_name.to_s]
      if evaluator
        evaluator.call(context)
      else
        StrategyBuilder.logger.warn { "Unregistered condition evaluated: #{condition_name}" }
        false
      end
    end

    def self.registered?(name)
      @registry.key?(name.to_s)
    end

    def self.validate_condition_names!(names)
      unknown = Array(names).map(&:to_s).reject { |n| registered?(n) }
      return if unknown.empty?

      raise StrategyBuilder::ValidationError,
            "Unknown entry conditions (not in ConditionRegistry): #{unknown.join(', ')}"
    end

    def self.load_defaults!
      # 1. Session Breakout — Asia box (UTC) from SessionDetector, prefix-safe.
      register('asia_range_defined') do |ctx|
        box = SessionDetector.asia_session_box(ctx.candles, ctx.current_candle)
        next false unless box

        box[:high] > box[:low]
      end

      register('session_high_break') do |ctx|
        box = SessionDetector.asia_session_box(ctx.candles, ctx.current_candle)
        next false unless box && ctx.current_candle && ctx.previous_candle

        asia_high = box[:high]
        asia_low = box[:low]
        cur = ctx.current_candle[:close]
        prev = ctx.previous_candle[:close]

        if cur > asia_high && prev <= asia_high
          ctx.direction = :long
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = [ctx.atr * 1.5, cur - asia_low].min
          true
        elsif cur < asia_low && prev >= asia_low
          ctx.direction = :short
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = [ctx.atr * 1.5, asia_high - cur].min
          true
        else
          false
        end
      end

      register('volume_confirmation') do |ctx|
        ctx.volume_zscore >= 1.0
      end

      # 2. Mean Reversion — prefer Asia session box; fall back to swing extremes if box not ready.
      register('price_near_session_extreme') do |ctx|
        box = SessionDetector.asia_session_box(ctx.candles, ctx.current_candle, min_candles: 2,
                                                                                min_range_atr_fraction: 0.01)
        last_high, last_low = if box
                                [{ price: box[:high] }, { price: box[:low] }]
                              else
                                [ctx.swing_points[:highs].last, ctx.swing_points[:lows].last]
                              end
        next false unless last_high && last_low && ctx.current_candle

        if (ctx.current_candle[:close] - last_low[:price]).abs < ctx.atr * 0.5
          ctx.direction = :long
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr
          true
        elsif (ctx.current_candle[:close] - last_high[:price]).abs < ctx.atr * 0.5
          ctx.direction = :short
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr
          true
        else
          false
        end
      end

      register('rsi_divergence') do |ctx|
        rsi = ctx.rsi
        next false unless rsi

        if ctx.direction == :long && rsi < 35
          true
        elsif ctx.direction == :short && rsi > 65
          true
        else
          false
        end
      end

      register('volume_decline') do |ctx|
        ctx.volume_zscore < 1.0
      end

      # 3. MTF Pullback Conditions
      register('higher_tf_trend_bullish') do |ctx|
        ctx.higher_tf_structure == :bullish
      end

      register('lower_tf_pullback_to_ema') do |ctx|
        ema_20 = ctx.ema(period: 20)
        next false if ema_20.empty?

        ema_current = ema_20.last
        distance = (ctx.current_candle[:close] - ema_current).abs / (ctx.atr + 0.0001)
        distance < 0.5
      end

      register('structure_hold') do |ctx|
        sp = ctx.swing_points
        last_low = sp[:lows].last
        next false unless last_low && ctx.current_candle

        ctx.current_candle[:close] > (last_low[:price] - ctx.atr * 0.25)
      end

      register('trigger_candle') do |ctx|
        next false unless ctx.current_candle && ctx.previous_candle

        if ctx.structure == :bullish && ctx.current_candle[:close] > ctx.previous_candle[:close]
          ctx.direction = :long
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.5
          true
        elsif ctx.structure == :bearish && ctx.current_candle[:close] < ctx.previous_candle[:close]
          ctx.direction = :short
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.5
          true
        else
          false
        end
      end

      # 4. Compression Breakout
      register('compression_detected') do |ctx|
        recent_regime = VolatilityProfile.regime(ctx.candles[0...-5])
        recent_regime == :compression
      end

      register('range_break') do |ctx|
        current_range = ctx.current_candle[:high] - ctx.current_candle[:low]
        expansion = ctx.atr.positive? ? current_range / ctx.atr : 0

        if expansion > 1.3
          ctx.direction = ctx.current_candle[:close] > ctx.current_candle[:open] ? :long : :short
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.0
          true
        else
          false
        end
      end

      register('volume_surge') do |ctx|
        ctx.volume_zscore >= 1.5
      end

      register('direction_bias') do |ctx|
        !ctx.direction.nil?
      end

      # 5. Failed Breakout
      register('breakout_attempt') do |ctx|
        last_high = ctx.swing_points[:highs].last
        last_low = ctx.swing_points[:lows].last
        next false unless ctx.candles.size >= 5

        recent = ctx.candles.last(5)
        if last_high && recent.any? { |c| c[:high] > last_high[:price] }
          ctx.direction = :short
          true
        elsif last_low && recent.any? { |c| c[:low] < last_low[:price] }
          ctx.direction = :long
          true
        else
          false
        end
      end

      register('retest_below_level') do |ctx|
        last_high = ctx.swing_points[:highs].last
        last_low = ctx.swing_points[:lows].last

        if ctx.direction == :short && last_high && ctx.current_candle[:close] < last_high[:price]
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.0
          true
        elsif ctx.direction == :long && last_low && ctx.current_candle[:close] > last_low[:price]
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.0
          true
        else
          false
        end
      end

      register('rejection_candle') do |ctx|
        if ctx.direction == :short
          wick_ratio = (ctx.current_candle[:high] - ctx.current_candle[:close]) / (ctx.current_candle[:high] - ctx.current_candle[:low] + 0.0001)
          wick_ratio >= 0.5
        elsif ctx.direction == :long
          wick_ratio = (ctx.current_candle[:close] - ctx.current_candle[:low]) / (ctx.current_candle[:high] - ctx.current_candle[:low] + 0.0001)
          wick_ratio >= 0.5
        else
          false
        end
      end

      register('volume_divergence') do |ctx|
        zs = VolumeProfile.volume_zscore(ctx.candles).compact
        next false if zs.size < 12

        window = zs.last(8)
        prior = zs[-12..-5]
        next false if prior.empty?

        ctx.volume_zscore < (prior.max * 0.85) && ctx.volume_zscore < window.max
      end

      # 6. VWAP Reclaim
      register('price_reclaims_vwap') do |ctx|
        vwap_vals = ctx.vwap
        vwap_current = vwap_vals.last
        vwap_prev = vwap_vals[-2]
        next false unless vwap_current && vwap_prev && ctx.previous_candle

        if ctx.previous_candle[:close] < vwap_prev && ctx.current_candle[:close] > vwap_current
          ctx.direction = :long
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.5
          true
        elsif ctx.previous_candle[:close] > vwap_prev && ctx.current_candle[:close] < vwap_current
          ctx.direction = :short
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.5
          true
        else
          false
        end
      end

      register('structure_bullish_shift') do |ctx|
        candles = ctx.candles
        next false if candles.size < 40

        early = StructureDetector.structure(candles[0...-20])
        late = StructureDetector.structure(candles)
        late == :bullish && early != :bullish
      end

      register('volume_on_reclaim') do |ctx|
        ctx.volume_zscore >= 1.0
      end

      register('momentum_confirmation') do |ctx|
        rsi = ctx.rsi
        if ctx.direction == :long
          rsi && rsi >= 45
        elsif ctx.direction == :short
          rsi && rsi <= 55
        else
          false
        end
      end

      # Generic fallback
      register('generic_breakout') do |ctx|
        last_high = ctx.swing_points[:highs].last
        last_low = ctx.swing_points[:lows].last
        next false unless last_high && last_low && ctx.current_candle && ctx.previous_candle

        if ctx.current_candle[:close] > last_high[:price] && ctx.previous_candle[:close] <= last_high[:price]
          ctx.direction = :long
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.5
          true
        elsif ctx.current_candle[:close] < last_low[:price] && ctx.previous_candle[:close] >= last_low[:price]
          ctx.direction = :short
          ctx.entry_price = ctx.current_candle[:close]
          ctx.stop_distance = ctx.atr * 1.5
          true
        else
          false
        end
      end
    end
  end

  ConditionRegistry.load_defaults!
end
