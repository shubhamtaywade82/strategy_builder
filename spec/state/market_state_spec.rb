# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::State::MarketState do
  def build_state(overrides = {})
    described_class.new(
      instrument:        "B-BTC_USDT",
      snapshot_at:       Time.utc(2024, 1, 15, 10, 0),
      primary_timeframe: "5m",
      regime:            :trend_up,
      session:           :london,
      higher_tf_bias:    :bullish,
      mid_tf_structure:  :higher_high_higher_low,
      lower_tf_state:    :pullback_into_support,
      volatility:        :normal,
      volume:            :expanding,
      liquidity:         { equal_highs: [], equal_lows: [], nearest_resist: nil, nearest_support: nil },
      bias:              :long,
      raw_features:      {},
      **overrides
    )
  end

  describe "#valid?" do
    it "returns true for a fully populated state" do
      expect(build_state.valid?).to be true
    end

    it "returns false when instrument is nil" do
      expect(build_state(instrument: nil).valid?).to be false
    end

    it "returns false when instrument is empty" do
      expect(build_state(instrument: "").valid?).to be false
    end

    it "returns false for unknown regime" do
      expect(build_state(regime: :unknown_regime).valid?).to be false
    end

    it "returns false for unknown bias" do
      expect(build_state(bias: :sideways).valid?).to be false
    end
  end

  describe "#to_llm_context" do
    subject(:ctx) { build_state.to_llm_context }

    it "includes all key fields" do
      expect(ctx).to include(:instrument, :regime, :session, :bias, :volatility, :volume)
    end

    it "excludes raw_features to keep prompt compact" do
      expect(ctx).not_to have_key(:raw_features)
    end

    it "serializes snapshot_at as ISO8601 string" do
      expect(ctx[:snapshot_at]).to be_a(String)
    end

    it "includes liquidity summary" do
      expect(ctx[:liquidity]).to be_a(Hash)
    end
  end
end
