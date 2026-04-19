# frozen_string_literal: true

module StrategyBuilder
  module State
    class LiquidityMapBuilder
      EQUAL_LEVEL_PCT = 0.001

      def self.build(features)
        swing_highs = features.dig(:structure, :swing_highs) || []
        swing_lows  = features.dig(:structure, :swing_lows)  || []

        high_prices = swing_highs.map { |s| s[:price].to_f }.reject(&:zero?)
        low_prices  = swing_lows.map  { |s| s[:price].to_f }.reject(&:zero?)

        current_close = current_close_price(features)

        {
          equal_highs:     cluster_levels(high_prices),
          equal_lows:      cluster_levels(low_prices),
          buy_side_pool:   low_prices.min(3),
          sell_side_pool:  high_prices.max(3),
          nearest_support: nearest_level(low_prices, :below, current_close),
          nearest_resist:  nearest_level(high_prices, :above, current_close)
        }
      end

      private

      def self.cluster_levels(prices)
        return [] if prices.empty?

        sorted = prices.sort
        groups = []
        current_group = [sorted.first]

        sorted[1..].each do |price|
          ref = current_group.first
          if (price - ref).abs / ref <= EQUAL_LEVEL_PCT
            current_group << price
          else
            groups << { price: current_group.sum / current_group.size.to_f, count: current_group.size }
            current_group = [price]
          end
        end
        groups << { price: current_group.sum / current_group.size.to_f, count: current_group.size }

        groups.select { |g| g[:count] >= 2 }.sort_by { |g| -g[:count] }
      end

      def self.nearest_level(prices, side, current_close)
        return nil if prices.empty? || current_close.nil? || current_close.zero?

        candidates = case side
                     when :below then prices.select { |p| p < current_close }
                     when :above then prices.select { |p| p > current_close }
                     end

        return nil if candidates.empty?

        case side
        when :below then candidates.max
        when :above then candidates.min
        end
      end

      def self.current_close_price(features)
        # Try to pull current price from per-timeframe summaries or raw candles
        per_tf = features[:per_timeframe_summary] || {}
        return nil if per_tf.empty?

        # Not stored as close — use a fallback via raw_features if present
        nil
      end
    end
  end
end
