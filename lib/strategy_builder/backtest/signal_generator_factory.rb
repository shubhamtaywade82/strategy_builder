# frozen_string_literal: true

module StrategyBuilder
  class SignalGeneratorFactory
    # Produces a callable (lambda) that the BacktestEngine can invoke on each candle
    # to check for entry signals. The callable receives (candles_so_far, strategy)
    # and returns nil (no signal) or a signal hash { direction:, entry_price:, stop_distance:, size: }.
    #
    # Each strategy family maps to a specific signal evaluation function.
    # The factory never invents logic — it dispatches to deterministic condition checkers.

    MINIMUM_WARMUP = 50

    def self.build(strategy)
      family = strategy[:family]&.to_sym || :custom
      conditions = strategy.dig(:entry, :conditions) || []
      filters = strategy[:filters] || {}
      sessions = strategy[:session] || []

      lambda do |candles, _strat|
        return nil if candles.size < MINIMUM_WARMUP

        # Evaluate family-specific entry logic
        signal = case family
                 when :session_breakout
                   evaluate_session_breakout(candles, conditions, sessions)
                 when :session_mean_reversion
                   evaluate_session_mean_reversion(candles, conditions, sessions)
                 when :mtf_pullback
                   evaluate_mtf_pullback(candles, conditions)
                 when :compression_breakout
                   evaluate_compression_breakout(candles, conditions)
                 when :failed_breakout
                   evaluate_failed_breakout(candles, conditions)
                 when :vwap_reclaim
                   evaluate_vwap_reclaim(candles, conditions)
                 else
                   evaluate_generic_breakout(candles, conditions)
                 end

        next nil unless signal

        # Apply universal filters
        next nil unless passes_filters?(candles, filters)
        next nil unless passes_session_filter?(candles.last, sessions)

        signal
      end
    end

    # --- Family-specific evaluators ---

    def self.evaluate_session_breakout(candles, conditions, sessions)
      current = candles.last
      prev = candles[-2]
      return nil unless current && prev

      # Detect session range from prior session
      atr = VolatilityProfile.atr(candles).compact.last
      return nil unless atr && atr > 0

      # Use recent swing high as breakout level
      sp = StructureDetector.swing_points(candles.last(100))
      last_high = sp[:highs].last
      last_low = sp[:lows].last
      return nil unless last_high && last_low

      # Long breakout: close breaks above swing high
      if current[:close] > last_high[:price] && prev[:close] <= last_high[:price]
        vol_zscore = VolumeProfile.volume_zscore(candles).compact.last || 0
        return nil if conditions.include?("volume_confirmation") && vol_zscore < 1.0

        return {
          direction: :long,
          entry_price: current[:close],
          stop_distance: [atr * 1.5, current[:close] - last_low[:price]].min,
          size: 1.0
        }
      end

      # Short breakout: close breaks below swing low
      if current[:close] < last_low[:price] && prev[:close] >= last_low[:price]
        vol_zscore = VolumeProfile.volume_zscore(candles).compact.last || 0
        return nil if conditions.include?("volume_confirmation") && vol_zscore < 1.0

        return {
          direction: :short,
          entry_price: current[:close],
          stop_distance: [atr * 1.5, last_high[:price] - current[:close]].min,
          size: 1.0
        }
      end

      nil
    end

    def self.evaluate_session_mean_reversion(candles, conditions, sessions)
      current = candles.last
      return nil unless current

      atr = VolatilityProfile.atr(candles).compact.last
      return nil unless atr && atr > 0

      rsi = MomentumEngine.rsi(candles).compact.last
      return nil unless rsi

      sp = StructureDetector.swing_points(candles.last(80))
      last_high = sp[:highs].last
      last_low = sp[:lows].last

      # Long mean reversion: price near swing low + RSI oversold
      if last_low && rsi < 35 && (current[:close] - last_low[:price]).abs < atr * 0.5
        return {
          direction: :long,
          entry_price: current[:close],
          stop_distance: atr,
          size: 1.0
        }
      end

      # Short mean reversion: price near swing high + RSI overbought
      if last_high && rsi > 65 && (current[:close] - last_high[:price]).abs < atr * 0.5
        return {
          direction: :short,
          entry_price: current[:close],
          stop_distance: atr,
          size: 1.0
        }
      end

      nil
    end

    def self.evaluate_mtf_pullback(candles, conditions)
      current = candles.last
      prev = candles[-2]
      return nil unless current && prev

      atr = VolatilityProfile.atr(candles).compact.last
      return nil unless atr && atr > 0

      # Check structure is bullish (HH+HL)
      structure = StructureDetector.structure(candles)

      # EMA pullback: price pulled back to EMA zone and bouncing
      closes = candles.map { |c| c[:close] }
      ema_20 = MomentumEngine.ema(closes, period: 20).compact
      return nil if ema_20.empty?

      ema_current = ema_20.last
      distance_to_ema = (current[:close] - ema_current).abs / atr

      # Bullish pullback: structure bullish, pulled back near EMA, now bouncing
      if structure == :bullish && distance_to_ema < 0.5 && current[:close] > prev[:close]
        return {
          direction: :long,
          entry_price: current[:close],
          stop_distance: atr * 1.5,
          size: 1.0
        }
      end

      # Bearish pullback: structure bearish, pulled back near EMA, now falling
      if structure == :bearish && distance_to_ema < 0.5 && current[:close] < prev[:close]
        return {
          direction: :short,
          entry_price: current[:close],
          stop_distance: atr * 1.5,
          size: 1.0
        }
      end

      nil
    end

    def self.evaluate_compression_breakout(candles, conditions)
      current = candles.last
      prev = candles[-2]
      return nil unless current && prev

      atr = VolatilityProfile.atr(candles).compact.last
      return nil unless atr && atr > 0

      regime = VolatilityProfile.regime(candles)

      # Need compression in recent history followed by current expansion
      recent_regime = VolatilityProfile.regime(candles[0...-5])
      return nil unless recent_regime == :compression

      # Range expansion on current candle
      current_range = current[:high] - current[:low]
      expansion = atr > 0 ? current_range / atr : 0
      return nil unless expansion > 1.3

      # Volume confirmation
      vol_zscore = VolumeProfile.volume_zscore(candles).compact.last || 0
      return nil if conditions.include?("volume_surge") && vol_zscore < 1.5

      direction = current[:close] > current[:open] ? :long : :short

      {
        direction: direction,
        entry_price: current[:close],
        stop_distance: atr * 1.0,
        size: 1.0
      }
    end

    def self.evaluate_failed_breakout(candles, conditions)
      current = candles.last
      return nil unless current

      atr = VolatilityProfile.atr(candles).compact.last
      return nil unless atr && atr > 0

      sp = StructureDetector.swing_points(candles.last(100))
      last_high = sp[:highs].last
      last_low = sp[:lows].last

      # Failed breakout long (price broke above high, then reversed back below)
      if last_high && candles.size >= 5
        recent = candles.last(5)
        broke_above = recent.any? { |c| c[:high] > last_high[:price] }
        closed_below = current[:close] < last_high[:price]

        if broke_above && closed_below
          wick_ratio = (current[:high] - current[:close]) / (current[:high] - current[:low] + 0.0001)
          return nil if conditions.include?("rejection_candle") && wick_ratio < 0.5

          return {
            direction: :short,
            entry_price: current[:close],
            stop_distance: atr * 1.0,
            size: 1.0
          }
        end
      end

      # Failed breakout short (price broke below low, then reversed back above)
      if last_low && candles.size >= 5
        recent = candles.last(5)
        broke_below = recent.any? { |c| c[:low] < last_low[:price] }
        closed_above = current[:close] > last_low[:price]

        if broke_below && closed_above
          wick_ratio = (current[:close] - current[:low]) / (current[:high] - current[:low] + 0.0001)
          return nil if conditions.include?("rejection_candle") && wick_ratio < 0.5

          return {
            direction: :long,
            entry_price: current[:close],
            stop_distance: atr * 1.0,
            size: 1.0
          }
        end
      end

      nil
    end

    def self.evaluate_vwap_reclaim(candles, conditions)
      current = candles.last
      prev = candles[-2]
      return nil unless current && prev

      atr = VolatilityProfile.atr(candles).compact.last
      return nil unless atr && atr > 0

      vwap_vals = VolumeProfile.vwap(candles)
      vwap_current = vwap_vals.last
      vwap_prev = vwap_vals[-2]
      return nil unless vwap_current && vwap_prev

      # Bullish reclaim: was below VWAP, now reclaimed above
      if prev[:close] < vwap_prev && current[:close] > vwap_current
        rsi = MomentumEngine.rsi(candles).compact.last
        return nil if conditions.include?("momentum_confirmation") && rsi && rsi < 45

        return {
          direction: :long,
          entry_price: current[:close],
          stop_distance: atr * 1.5,
          size: 1.0
        }
      end

      # Bearish rejection: was above VWAP, now lost it
      if prev[:close] > vwap_prev && current[:close] < vwap_current
        rsi = MomentumEngine.rsi(candles).compact.last
        return nil if conditions.include?("momentum_confirmation") && rsi && rsi > 55

        return {
          direction: :short,
          entry_price: current[:close],
          stop_distance: atr * 1.5,
          size: 1.0
        }
      end

      nil
    end

    def self.evaluate_generic_breakout(candles, conditions)
      # Fallback: simple structure breakout
      current = candles.last
      prev = candles[-2]
      return nil unless current && prev

      atr = VolatilityProfile.atr(candles).compact.last
      return nil unless atr && atr > 0

      sp = StructureDetector.swing_points(candles.last(80))
      last_high = sp[:highs].last
      last_low = sp[:lows].last

      if last_high && current[:close] > last_high[:price] && prev[:close] <= last_high[:price]
        { direction: :long, entry_price: current[:close], stop_distance: atr * 1.5, size: 1.0 }
      elsif last_low && current[:close] < last_low[:price] && prev[:close] >= last_low[:price]
        { direction: :short, entry_price: current[:close], stop_distance: atr * 1.5, size: 1.0 }
      end
    end

    # --- Universal filters ---

    def self.passes_filters?(candles, filters)
      if filters[:min_volume_zscore]
        zscore = VolumeProfile.volume_zscore(candles).compact.last
        return false if zscore && zscore < filters[:min_volume_zscore]
      end

      if filters[:min_atr_percent]
        atr_pct = VolatilityProfile.atr_percent(candles).compact.last
        return false if atr_pct && atr_pct < filters[:min_atr_percent]
      end

      if filters[:max_atr_percent]
        atr_pct = VolatilityProfile.atr_percent(candles).compact.last
        return false if atr_pct && atr_pct > filters[:max_atr_percent]
      end

      if filters[:required_regime]
        regime = VolatilityProfile.regime(candles)
        allowed = filters[:required_regime].map { |r| r.is_a?(String) ? r.to_sym : r }
        return false unless allowed.include?(regime)
      end

      if filters[:required_structure]
        structure = StructureDetector.structure(candles)
        allowed = filters[:required_structure].map { |s| s.is_a?(String) ? s.to_sym : s }
        return false unless allowed.include?(structure)
      end

      if filters[:min_mtf_alignment]
        # MTF alignment requires multi-timeframe data which isn't available
        # in single-TF backtest context. Skip this filter in backtest.
      end

      true
    end

    def self.passes_session_filter?(candle, sessions)
      return true if sessions.nil? || sessions.empty? || sessions.include?("any")

      tagged = SessionDetector.tag_candles([candle]).first
      candle_sessions = tagged[:sessions]

      sessions.any? { |s| candle_sessions.include?(s) }
    end
  end
end
