# frozen_string_literal: true

module StrategyBuilder
  class FillModel
    # Immediate full fill at the simulated price produced by SlippageModel (+ spread).
    # Partial fills / queue depth are not modeled; reserved for a future execution simulator.
    def fill(price, size, _candle)
      { filled_price: price, filled_size: size, partial: false }
    end
  end

  class SlippageModel
    def initialize(slippage_bps: nil, spread_bps: nil, volatility_scaled: nil)
      cfg = StrategyBuilder.configuration
      @slippage_bps = slippage_bps || cfg.backtest_slippage_bps
      @spread_bps = spread_bps || cfg.backtest_spread_bps
      @volatility_scaled = volatility_scaled.nil? ? cfg.backtest_slippage_volatility_scale : volatility_scaled
    end

    # Adverse execution price: slippage + half-spread per side (mid proxy = +raw+).
    # +direction+ is position side: :long entry buys; :short entry sells; exits use reverse_direction.
    def apply(price, direction, candle, candles_so_far: nil)
      slip = adverse_slippage_amount(price, direction, candle, candles_so_far)
      half_spread = price * (@spread_bps / 10_000.0) / 2.0
      case direction
      when :long  then price + slip + half_spread
      when :short then price - slip - half_spread
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
