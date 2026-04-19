# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::State::SnapshotBuilder do
  def base_features(overrides = {})
    {
      instrument:        "B-BTC_USDT",
      primary_timeframe: "5m",
      sessions:          ["london"],
      volatility:        { regime: :compression },
      structure: {
        structure:   :bullish,
        swing_highs: [{ price: 105.0, index: 10, timestamp: 0 }],
        swing_lows:  [{ price: 95.0,  index: 5,  timestamp: 0 }]
      },
      mtf_alignment: {
        alignment: {
          alignment:       0.8,
          aligned_bullish: true,
          aligned_bearish: false,
          conflicting:     false,
          regime:          :strong_bullish
        }
      },
      volume: { volume_zscore: 1.5 },
      per_timeframe_summary: {
        "15m" => { trend: :bullish, structure: :bullish, volatility_regime: :normal },
        "1h"  => { trend: :bullish, structure: :bullish, volatility_regime: :normal }
      }
    }.merge(overrides)
  end

  describe ".build" do
    subject(:state) { described_class.build(instrument: "B-BTC_USDT", features: base_features) }

    it "returns a MarketState" do
      expect(state).to be_a(StrategyBuilder::State::MarketState)
    end

    it "is valid" do
      expect(state.valid?).to be true
    end

    it "sets instrument" do
      expect(state.instrument).to eq("B-BTC_USDT")
    end

    it "classifies compression regime correctly" do
      expect(state.regime).to eq(:compression)
    end

    it "maps london session" do
      expect(state.session).to eq(:london)
    end

    it "derives bullish higher_tf_bias from aligned_bullish" do
      expect(state.higher_tf_bias).to eq(:bullish)
    end

    it "derives :long bias from compression + bullish HTF" do
      expect(state.bias).to eq(:long)
    end

    it "labels contracting volatility for compression regime" do
      expect(state.volatility).to eq(:contracting)
    end

    it "labels expanding volume for high zscore" do
      expect(state.volume).to eq(:expanding)
    end

    it "includes liquidity map" do
      expect(state.liquidity).to be_a(Hash)
      expect(state.liquidity).to have_key(:equal_highs)
    end

    it "falls back to :closed for no sessions" do
      state = described_class.build(instrument: "B-BTC_USDT", features: base_features(sessions: []))
      expect(state.session).to eq(:closed)
    end

    it "sets :neutral bias for chop + neutral HTF" do
      features = base_features(
        volatility:    { regime: :normal },
        structure:     { structure: :ranging, swing_highs: [], swing_lows: [] },
        mtf_alignment: { alignment: { aligned_bullish: false, aligned_bearish: false, regime: :neutral } }
      )
      state = described_class.build(instrument: "B-BTC_USDT", features: features)
      expect(state.bias).to eq(:neutral)
    end
  end
end
