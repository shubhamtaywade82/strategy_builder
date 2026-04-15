# frozen_string_literal: true

module StrategyBuilder
  class BacktestEngine
    # Event-driven backtester. Walks candles forward, evaluates entry/exit signals,
    # simulates fills with slippage and fees, tracks positions and PnL.

    POSITION_STATES = %i[idle signal_detected entry_pending position_open exit_pending closed].freeze

    Position = Struct.new(
      :id, :direction, :entry_price, :entry_time, :entry_index, :size, :stop_price,
      :targets, :partial_exits, :trail_config, :state,
      :fills, :pnl, :exit_price, :exit_time, :exit_reason,
      :remaining_size, :be_shifted, :current_trail_stop,
      keyword_init: true
    )

    Trade = Struct.new(
      :position_id, :direction, :entry_price, :exit_price, :entry_time, :exit_time,
      :size, :pnl, :pnl_r, :fees, :slippage, :exit_reason, :hold_candles,
      keyword_init: true
    )

    def initialize(
      fee_model: FeeModel.new,
      slippage_model: SlippageModel.new,
      fill_model: FillModel.new,
      trailing_model: TrailingModel.new,
      partial_exit_model: PartialExitModel.new
    )
      @fee_model = fee_model
      @slippage_model = slippage_model
      # Reserved for future partial-fill / queue simulation; entry/exit prices use SlippageModel today.
      @fill_model = fill_model
      @trailing_model = trailing_model
      @partial_exit_model = partial_exit_model
      @logger = StrategyBuilder.logger
    end

    # Run backtest for a strategy candidate on candle data.
    # signal_generator: a callable that receives (candles_prefix, strategy) -> signal or nil
    # (candles_prefix is the same Array instance, grown by one candle per bar — no per-bar slice allocation).
    # Returns: { trades: [...], metrics: {...} }
    def run(strategy:, candles:, signal_generator:, mtf_candles: nil)
      trades = []
      position = nil
      position_counter = 0
      warmup = StrategyBuilder.configuration.backtest_indicator_warmup
      candles_prefix = []

      candles.each_with_index do |candle, i|
        candles_prefix << candle
        next if i < warmup

        # If in position, check exits first
        if position && BacktestPositionState.active?(position)
          exit_result = check_exits(position, candle, i, strategy, candles_prefix)
          if exit_result
            trade = close_position(position, exit_result, candle, i, candles_prefix)
            trades << trade
            position = nil
          elsif position.trail_config
            # Update trailing stop
            position = @trailing_model.update(position, candle)
          end
        end

        # If no position, check for entry signals
        next if position

        signal = signal_generator.call(candles_prefix, strategy, mtf_candles)
        next unless signal

        # Apply filters
        next unless passes_filters?(signal, candles_prefix, strategy)

        position_counter += 1
        position = open_position(signal, candle, i, position_counter, strategy, candles_prefix)
      end

      # Force-close any open position at end
      if position && BacktestPositionState.active?(position)
        trade = close_position(
          position,
          { reason: :end_of_data, price: candles.last[:close] },
          candles.last,
          candles.size - 1,
          candles_prefix
        )
        trades << trade
      end

      metrics = Metrics.compute(trades)
      { trades: trades, metrics: metrics, strategy_name: strategy[:name] }
    end

    private

    def open_position(signal, candle, index, counter, strategy, candles_prefix)
      direction = signal[:direction] || :long
      raw_entry = signal[:entry_price] || candle[:close]
      entry_price = @slippage_model.apply(raw_entry, direction, candle, candles_so_far: candles_prefix)
      entry_fee = @fee_model.calculate(entry_price, signal[:size] || 1.0)

      stop_distance = compute_stop_distance(strategy, candle, signal)
      stop_price = direction == :long ? entry_price - stop_distance : entry_price + stop_distance

      targets = (strategy.dig(:exit, :targets) || [1.0, 2.0]).map do |r_multiple|
        direction == :long ? entry_price + (stop_distance * r_multiple) : entry_price - (stop_distance * r_multiple)
      end

      Position.new(
        id: counter,
        direction: direction,
        entry_price: entry_price,
        entry_time: candle[:timestamp],
        entry_index: index,
        size: signal[:size] || 1.0,
        remaining_size: signal[:size] || 1.0,
        stop_price: stop_price,
        targets: targets,
        partial_exits: strategy.dig(:exit, :partial_exits) || [1.0],
        trail_config: strategy.dig(:exit, :trail),
        state: :position_open,
        fills: [{ price: entry_price, fee: entry_fee, time: candle[:timestamp] }],
        pnl: -entry_fee,
        be_shifted: false,
        current_trail_stop: stop_price
      )
    end

    def check_exits(position, candle, index, strategy, candles_prefix)
      BacktestPositionState.ensure_active_for_exits!(position)

      # 1. Stop loss hit
      if stop_hit?(position, candle)
        return { reason: :stop_loss, price: position.current_trail_stop || position.stop_price }
      end

      # 2. Target hits (partial exits handled by model)
      target_result = @partial_exit_model.check(position, candle)
      if target_result && target_result[:full_exit]
        return { reason: :target_hit, price: target_result[:price] }
      elsif target_result
        # Partial exit — update position but don't close
        apply_partial_exit(position, target_result, candle, candles_prefix)
        return nil
      end

      # 3. Time stop
      if strategy.dig(:exit, :time_stop_candles)
        entry_idx = position.entry_index
        if entry_idx && (index - entry_idx) >= strategy[:exit][:time_stop_candles]
          return { reason: :time_stop, price: candle[:close] }
        end
      end

      nil
    end

    def stop_hit?(position, candle)
      stop = position.current_trail_stop || position.stop_price
      if position.direction == :long
        candle[:low] <= stop
      else
        candle[:high] >= stop
      end
    end

    def apply_partial_exit(position, result, candle, candles_prefix)
      # Fractions are shares of original position.size (e.g. 0.33/0.33/0.34), not of remaining_size.
      exit_size = (position.size * result[:fraction])
      exit_size = [exit_size, position.remaining_size].min
      exit_price = @slippage_model.apply(
        result[:price],
        reverse_direction(position.direction),
        candle,
        candles_so_far: candles_prefix
      )
      fee = @fee_model.calculate(exit_price, exit_size)

      pnl = if position.direction == :long
              (exit_price - position.entry_price) * exit_size - fee
            else
              (position.entry_price - exit_price) * exit_size - fee
            end

      position.remaining_size -= exit_size
      position.pnl += pnl
      position.fills << { price: exit_price, fee: fee, size: exit_size, type: :partial_exit }
    end

    def close_position(position, exit_result, candle, index, candles_prefix)
      raw_exit = exit_result[:price]
      exit_price = @slippage_model.apply(
        raw_exit,
        reverse_direction(position.direction),
        candle,
        candles_so_far: candles_prefix
      )
      exit_fee = @fee_model.calculate(exit_price, position.remaining_size)

      final_pnl = if position.direction == :long
                    (exit_price - position.entry_price) * position.remaining_size - exit_fee
                  else
                    (position.entry_price - exit_price) * position.remaining_size - exit_fee
                  end

      total_pnl = position.pnl + final_pnl
      stop_distance = (position.entry_price - position.stop_price).abs
      pnl_r = stop_distance.zero? ? 0.0 : total_pnl / (stop_distance * position.size)

      entry_idx = position.entry_index
      hold_bars = entry_idx ? (index - entry_idx) : index

      Trade.new(
        position_id: position.id,
        direction: position.direction,
        entry_price: position.entry_price,
        exit_price: exit_price,
        entry_time: position.entry_time,
        exit_time: candle[:timestamp],
        size: position.size,
        pnl: total_pnl,
        pnl_r: pnl_r,
        fees: position.fills.sum { |f| f[:fee] || 0 } + exit_fee,
        slippage: 0.0, # adverse slippage is applied in prices via SlippageModel, not accumulated here
        exit_reason: exit_result[:reason],
        hold_candles: hold_bars
      )
    end

    def compute_stop_distance(_strategy, candle, signal)
      # Default: use ATR-based stop if no explicit distance
      signal[:stop_distance] || candle[:close] * StrategyBuilder.configuration.backtest_default_stop_price_fraction
    end

    def passes_filters?(_signal, candles, strategy)
      filters = strategy[:filters] || {}

      if filters[:min_volume_zscore]
        zscore = VolumeProfile.volume_zscore(candles).compact.last
        return false if zscore && zscore < filters[:min_volume_zscore]
      end

      if filters[:min_atr_percent]
        atr_pct = VolatilityProfile.atr_percent(candles).compact.last
        return false if atr_pct && atr_pct < filters[:min_atr_percent]
      end

      if filters[:required_regime]
        regime = VolatilityProfile.regime(candles)
        return false unless filters[:required_regime].map(&:to_sym).include?(regime)
      end

      true
    end

    def reverse_direction(direction)
      direction == :long ? :short : :long
    end
  end
end
