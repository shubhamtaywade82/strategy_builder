# frozen_string_literal: true

module StrategyBuilder
  class FillModel
    # Volume-proportional fill: large orders relative to candle volume get partial fills.
    # Small orders (< 5% of candle volume) fill in full immediately.
    FULL_FILL_RATIO  = 0.05  # orders < 5% of candle volume fill 100%
    MAX_FILL_PENALTY = 0.70  # orders can be at most 70% unfilled

    def fill(price, size, candle)
      volume = candle[:volume].to_f
      if volume <= 0
        return { filled_price: price, filled_size: size, partial: false }
      end

      volume_ratio = size / volume
      if volume_ratio < FULL_FILL_RATIO
        { filled_price: price, filled_size: size, partial: false }
      else
        penalty     = [volume_ratio * 0.3, MAX_FILL_PENALTY].min
        filled_size = size * (1.0 - penalty)
        filled_size = [filled_size, size].min
        { filled_price: price, filled_size: filled_size, partial: true }
      end
    end
  end

  class SlippageModel
    def initialize(slippage_bps: nil, spread_bps: nil, volatility_scaled: nil, latency_ms: 200)
      cfg = StrategyBuilder.configuration
      @slippage_bps = slippage_bps || cfg.backtest_slippage_bps
      @spread_bps = spread_bps || cfg.backtest_spread_bps
      @volatility_scaled = volatility_scaled.nil? ? cfg.backtest_slippage_volatility_scale : volatility_scaled
      @latency_ms = latency_ms
    end

    # Adverse execution price: slippage + half-spread per side (mid proxy = +raw+).
    # +direction+ is position side: :long entry buys; :short entry sells; exits use reverse_direction.
    def apply(price, direction, candle, candles_so_far: nil)
      slip = adverse_slippage_amount(price, direction, candle, candles_so_far)
      
      # Dynamic spread: widen spread during high volatility
      dynamic_spread = @spread_bps
      if @volatility_scaled && candles_so_far.is_a?(Array) && candles_so_far.size > 25
        atrp = VolatilityProfile.atr_percent(candles_so_far).compact.last
        if atrp && atrp > 2.0
          dynamic_spread *= 1.5 # Widen spread by 50% during high vol
        end
      end
      
      half_spread = price * (dynamic_spread / 10_000.0) / 2.0
      
      # Latency penalty: fast markets move away from us during the 200ms routing delay
      latency_penalty = 0.0
      if @latency_ms > 0 && candle[:high] > candle[:low]
        # Assume price moves against us by 1% of the candle's range per 100ms of latency during a breakout
        latency_penalty = (candle[:high] - candle[:low]) * 0.01 * (@latency_ms / 100.0)
      end

      case direction
      when :long  then price + slip + half_spread + latency_penalty
      when :short then price - slip - half_spread - latency_penalty
      else price
      end
    end

    private

    def adverse_slippage_amount(price, _direction, _candle, candles_so_far)
      base = price * (@slippage_bps / 10_000.0)
      mult = 1.0
      if @volatility_scaled && candles_so_far.is_a?(Array) && candles_so_far.size > 25
        atrp = VolatilityProfile.atr_percent(candles_so_far).compact.last
        mult += [[atrp.to_f / 2.0, 0.0].max, 2.5].min if atrp
      end
      base * mult
    end
  end

  class FeeModel
    def initialize(fee_rate: nil)
      @fee_rate = fee_rate || StrategyBuilder.configuration.backtest_fee_rate
    end

    # Calculate trading fee for a fill.
    def calculate(price, size)
      (price * size * @fee_rate).abs
    end
  end

  class PartialExitModel
    # Check if any target has been hit and compute partial exit.
    # Returns nil if no target hit, or { fraction:, price:, full_exit: } hash.
    def check(position, candle)
      targets = position.targets || []
      partials = position.partial_exits || [1.0]

      targets.each_with_index do |target, i|
        fraction = partials[i] || partials.last || 1.0
        hit = if position.direction == :long
                candle[:high] >= target
              else
                candle[:low] <= target
              end

        next unless hit

        # Planned exit leg: fraction of *original* size, capped by what is still open.
        exit_leg_size = (position.size * fraction)
        exit_leg_size = [exit_leg_size, position.remaining_size].min

        # Remove this target from position
        remaining_targets = targets[(i + 1)..]
        position.targets = remaining_targets

        # Adjust partial exits list
        remaining_partials = partials[(i + 1)..] || []
        position.partial_exits = remaining_partials

        is_full = remaining_targets.empty? || (position.remaining_size - exit_leg_size) <= 1e-9

        # Shift stop to breakeven after first target
        if i.zero? && !position.be_shifted
          position.current_trail_stop = position.entry_price
          position.be_shifted = true
        end

        return { fraction: fraction, price: target, full_exit: is_full, target_index: i }
      end

      nil
    end
  end

  class TrailingModel
    # Update trailing stop based on strategy configuration.
    # Supports: atr_trailing, percent_trailing, fixed_distance.
    def update(position, candle)
      trail_config = position.trail_config
      return position unless trail_config.is_a?(String) && !trail_config.empty?

      case trail_config
      when /^atr_(\d+)_(\d+)/
        atr_multiplier = "#{::Regexp.last_match(1)}.#{::Regexp.last_match(2)}".to_f
        update_atr_trail(position, candle, atr_multiplier)
      when /^percent_(\d+)/
        percent = ::Regexp.last_match(1).to_f / 100.0
        update_percent_trail(position, candle, percent)
      else
        position # unknown trail config, no-op
      end
    end

    private

    def update_atr_trail(position, candle, multiplier)
      # Simplified: use candle range as ATR proxy for single-candle updates.
      atr_proxy = candle[:high] - candle[:low]
      trail_distance = atr_proxy * multiplier

      new_stop = if position.direction == :long
                   [position.current_trail_stop, candle[:high] - trail_distance].max
                 else
                   [position.current_trail_stop, candle[:low] + trail_distance].min
                 end

      position.current_trail_stop = new_stop
      position
    end

    def update_percent_trail(position, candle, percent)
      trail_distance = candle[:close] * percent

      new_stop = if position.direction == :long
                   [position.current_trail_stop, candle[:high] - trail_distance].max
                 else
                   [position.current_trail_stop, candle[:low] + trail_distance].min
                 end

      position.current_trail_stop = new_stop
      position
    end
  end
end
