# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Patterns::PatternMiner do
  def build_state(regime:, bias:, volatility: :normal, volume: :average, session: :london, htf_bias: :neutral)
    StrategyBuilder::State::MarketState.new(
      instrument:        "B-BTC_USDT",
      snapshot_at:       Time.now.utc,
      primary_timeframe: "5m",
      regime:            regime,
      session:           session,
      higher_tf_bias:    htf_bias,
      mid_tf_structure:  :ranging,
      lower_tf_state:    :compressing,
      volatility:        volatility,
      volume:            volume,
      liquidity:         { equal_highs: [], equal_lows: [] },
      bias:              bias,
      raw_features:      {}
    )
  end

  describe ".mine" do
    it "returns an array" do
      state = build_state(regime: :compression, bias: :long)
      expect(described_class.mine(state)).to be_an(Array)
    end

    it "returns patterns sorted by score descending" do
      state = build_state(regime: :compression, bias: :long, volatility: :contracting, volume: :expanding)
      result = described_class.mine(state)
      scores = result.map { |p| p[:score] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it "includes compression_breakout for compression regime" do
      state = build_state(regime: :compression, bias: :long)
      names = described_class.mine(state).map { |p| p[:name] }
      expect(names).to include(:compression_breakout)
    end

    it "includes pullback_continuation for trend_up + long bias" do
      state = build_state(regime: :trend_up, bias: :long)
      names = described_class.mine(state).map { |p| p[:name] }
      expect(names).to include(:pullback_continuation)
    end

    it "returns empty for chop regime" do
      state = build_state(regime: :chop, bias: :neutral)
      expect(described_class.mine(state)).to be_empty
    end

    it "filters out patterns below MIN_SCORE" do
      state = build_state(regime: :range, bias: :neutral, volume: :declining, volatility: :normal, htf_bias: :neutral)
      result = described_class.mine(state)
      result.each { |p| expect(p[:score]).to be >= described_class::MIN_SCORE }
    end

    it "returns pattern hash with required keys" do
      state = build_state(regime: :compression, bias: :long, volatility: :contracting)
      result = described_class.mine(state)
      expect(result.first).to include(:name, :score, :evidence, :description, :entry_type, :confirmation, :invalidation)
    end

    it "adds evidence strings" do
      state = build_state(regime: :compression, bias: :long, htf_bias: :bullish)
      result = described_class.mine(state).find { |p| p[:name] == :compression_breakout }
      expect(result[:evidence]).to be_an(Array)
      expect(result[:evidence]).not_to be_empty
    end
  end
end
