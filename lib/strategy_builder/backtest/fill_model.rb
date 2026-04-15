# frozen_string_literal: true

module StrategyBuilder
  class FillModel
    # Simulates order fills. For backtesting, assumes immediate fill at specified price.
    # Production extension: model partial fills, queue position, etc.
    def fill(price, size, candle)
      { filled_price: price, filled_size: size, partial: false }
    end
  end

  class SlippageModel
    def initialize(slippage_bps: nil)
      @slippage_bps = slippage_bps || StrategyBuilder.configuration.backtest_slippage_bps
    end

    # Apply slippage to a fill price.
    # Buys slip up, sells slip down (adverse fill).
    def apply(price, direction, candle)
      slip = price * (@slippage_bps / 10_000.0)
      case direction
      when :long  then price + slip
      when :short then price - slip
      else price
      end
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

        # Remove this target from position
        remaining_targets = targets[(i + 1)..]
        position.targets = remaining_targets

        # Adjust partial exits list
        remaining_partials = partials[(i + 1)..] || []
        position.partial_exits = remaining_partials

        is_full = remaining_targets.empty? || position.remaining_size * (1.0 - fraction) < 0.001

        # Shift stop to breakeven after first target
        if i == 0 && !position.be_shifted
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
        atr_multiplier = "#{$1}.#{$2}".to_f
        update_atr_trail(position, candle, atr_multiplier)
      when /^percent_(\d+)/
        percent = $1.to_f / 100.0
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
