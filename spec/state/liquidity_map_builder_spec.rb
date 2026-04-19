# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::State::LiquidityMapBuilder do
  def features_with_swings(highs:, lows:)
    {
      structure: {
        swing_highs: highs.map { |p| { price: p, index: 0, timestamp: 0 } },
        swing_lows:  lows.map  { |p| { price: p, index: 0, timestamp: 0 } }
      },
      per_timeframe_summary: {}
    }
  end

  describe ".build" do
    it "returns the expected keys" do
      result = described_class.build(features_with_swings(highs: [100.0, 101.0], lows: [95.0, 96.0]))
      expect(result.keys).to include(:equal_highs, :equal_lows, :buy_side_pool, :sell_side_pool, :nearest_support, :nearest_resist)
    end

    it "returns empty equal levels when no clustered prices" do
      result = described_class.build(features_with_swings(highs: [100.0, 200.0, 300.0], lows: [50.0, 150.0, 250.0]))
      expect(result[:equal_highs]).to be_empty
      expect(result[:equal_lows]).to be_empty
    end

    it "clusters prices within 0.1% as equal levels" do
      highs = [100.0, 100.05, 100.09]  # all within 0.1% of 100.0
      result = described_class.build(features_with_swings(highs: highs, lows: []))
      expect(result[:equal_highs].size).to eq(1)
      expect(result[:equal_highs].first[:count]).to eq(3)
    end

    it "returns buy_side_pool as the lowest 3 swing lows" do
      result = described_class.build(features_with_swings(highs: [], lows: [90.0, 85.0, 80.0, 70.0]))
      expect(result[:buy_side_pool]).to eq([70.0, 80.0, 85.0])
    end

    it "handles empty swing data without error" do
      result = described_class.build(features_with_swings(highs: [], lows: []))
      expect(result[:equal_highs]).to be_empty
      expect(result[:equal_lows]).to be_empty
      expect(result[:buy_side_pool]).to be_empty
      expect(result[:sell_side_pool]).to be_empty
    end
  end
end
