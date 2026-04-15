# frozen_string_literal: true

module StrategyBuilder
  class StructureDetector
    SWING_LOOKBACK = 5 # candles each side for swing detection

    # Detect swing highs and lows.
    # A swing high has lower highs on both sides.
    # A swing low has higher lows on both sides.
    def self.swing_points(candles, lookback: SWING_LOOKBACK)
      return { highs: [], lows: [] } if candles.size < (lookback * 2 + 1)

      highs = []
      lows = []

      (lookback...(candles.size - lookback)).each do |i|
        left_highs = candles[(i - lookback)...i].map { |c| c[:high] }
        right_highs = candles[(i + 1)..(i + lookback)].map { |c| c[:high] }
        current_high = candles[i][:high]

        if left_highs.all? { |h| h <= current_high } && right_highs.all? { |h| h <= current_high }
          highs << { index: i, price: current_high, timestamp: candles[i][:timestamp] }
        end

        left_lows = candles[(i - lookback)...i].map { |c| c[:low] }
        right_lows = candles[(i + 1)..(i + lookback)].map { |c| c[:low] }
        current_low = candles[i][:low]

        if left_lows.all? { |l| l >= current_low } && right_lows.all? { |l| l >= current_low }
          lows << { index: i, price: current_low, timestamp: candles[i][:timestamp] }
        end
      end

      { highs: highs, lows: lows }
    end

    # Classify the last N swing points into market structure.
    # Returns: :bullish (HH + HL), :bearish (LH + LL), :ranging, :unknown
    def self.structure(candles, lookback: SWING_LOOKBACK)
      sp = swing_points(candles, lookback: lookback)
      return :unknown if sp[:highs].size < 2 || sp[:lows].size < 2

      last_highs = sp[:highs].last(3).map { |h| h[:price] }
      last_lows = sp[:lows].last(3).map { |l| l[:price] }

      hh = last_highs.each_cons(2).all? { |a, b| b > a }
      hl = last_lows.each_cons(2).all? { |a, b| b > a }
      lh = last_highs.each_cons(2).all? { |a, b| b < a }
      ll = last_lows.each_cons(2).all? { |a, b| b < a }

      if hh && hl
        :bullish
      elsif lh && ll
        :bearish
      else
        :ranging
      end
    end

    # Detect market structure shift (MSS): the first opposite-direction structure break.
    # A bullish MSS = price breaks above a prior swing high after a bearish sequence.
    # A bearish MSS = price breaks below a prior swing low after a bullish sequence.
    def self.structure_shifts(candles, lookback: SWING_LOOKBACK)
      sp = swing_points(candles, lookback: lookback)
      shifts = []

      sp[:highs].each_cons(2) do |prev_high, curr_high|
        if curr_high[:price] > prev_high[:price]
          # Check if prior structure was bearish (LH)
          prior_highs = sp[:highs].select { |h| h[:index] < prev_high[:index] }.last(2)
          if prior_highs.size == 2 && prior_highs.last[:price] < prior_highs.first[:price]
            shifts << {
              type: :bullish_mss,
              trigger_index: curr_high[:index],
              trigger_price: curr_high[:price],
              timestamp: curr_high[:timestamp]
            }
          end
        end
      end

      sp[:lows].each_cons(2) do |prev_low, curr_low|
        if curr_low[:price] < prev_low[:price]
          prior_lows = sp[:lows].select { |l| l[:index] < prev_low[:index] }.last(2)
          if prior_lows.size == 2 && prior_lows.last[:price] > prior_lows.first[:price]
            shifts << {
              type: :bearish_mss,
              trigger_index: curr_low[:index],
              trigger_price: curr_low[:price],
              timestamp: curr_low[:timestamp]
            }
          end
        end
      end

      shifts.sort_by { |s| s[:trigger_index] }
    end

    # Detect breakout: close above prior swing high or below prior swing low.
    def self.breakout_signals(candles, lookback: SWING_LOOKBACK)
      sp = swing_points(candles, lookback: lookback)
      signals = []

      last_high = sp[:highs].last
      last_low = sp[:lows].last
      current = candles.last

      if last_high && current[:close] > last_high[:price]
        signals << { type: :breakout_long, level: last_high[:price], close: current[:close] }
      end

      if last_low && current[:close] < last_low[:price]
        signals << { type: :breakout_short, level: last_low[:price], close: current[:close] }
      end

      signals
    end

    # Full structure profile.
    def self.profile(candles, lookback: SWING_LOOKBACK)
      sp = swing_points(candles, lookback: lookback)
      {
        structure: structure(candles, lookback: lookback),
        swing_highs: sp[:highs].last(5),
        swing_lows: sp[:lows].last(5),
        structure_shifts: structure_shifts(candles, lookback: lookback).last(3),
        breakout_signals: breakout_signals(candles, lookback: lookback)
      }
    end
  end
end
