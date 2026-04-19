# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Agent::Roles::Skeptic do
  let(:client)  { instance_double(Ollama::Client) }
  let(:planner) { instance_double(StrategyBuilder::OllamaGeneratePlanner) }
  let(:skeptic) { described_class.new(client: client) }

  let(:market_state) do
    StrategyBuilder::State::MarketState.new(
      instrument:        "B-BTC_USDT",
      snapshot_at:       Time.now.utc,
      primary_timeframe: "5m",
      regime:            :trend_up,
      session:           :london,
      higher_tf_bias:    :bullish,
      mid_tf_structure:  :higher_high_higher_low,
      lower_tf_state:    :pullback_into_support,
      volatility:        :normal,
      volume:            :expanding,
      liquidity:         { equal_highs: [], equal_lows: [] },
      bias:              :long,
      raw_features:      {}
    )
  end

  let(:valid_candidate) { TestData.strategy_candidate }

  before do
    allow(StrategyBuilder::OllamaGeneratePlanner).to receive(:build).with(client).and_return(planner)
  end

  describe "#review — hard rejects (no LLM call)" do
    it "rejects candidate with all targets < 1R without calling LLM" do
      bad = valid_candidate.merge(exit: { targets: [0.5], partial_exits: [1.0], trail: "none" })
      result = skeptic.review(bad, market_state)
      expect(result).to be_nil
    end

    it "rejects candidate with empty entry conditions" do
      bad = valid_candidate.merge(entry: { conditions: [], direction: "long" })
      result = skeptic.review(bad, market_state)
      expect(result).to be_nil
    end

    it "rejects chop regime + non-mean-reversion family" do
      chop_state = market_state.dup
      allow(chop_state).to receive(:regime).and_return(:chop)
      bad = valid_candidate.merge(family: "compression_breakout")
      result = skeptic.review(bad, chop_state)
      expect(result).to be_nil
    end
  end

  describe "#review — LLM decision" do
    before do
      allow(planner).to receive(:run).and_return({ "accepted" => true, "concerns" => ["watch volume"] })
    end

    it "returns annotated candidate when LLM accepts" do
      result = skeptic.review(valid_candidate, market_state)
      expect(result).not_to be_nil
      expect(result[:skeptic_notes]).to eq(["watch volume"])
    end

    it "returns nil when LLM rejects" do
      allow(planner).to receive(:run).and_return({ "accepted" => false, "rejection_reason" => "entry too late" })
      result = skeptic.review(valid_candidate, market_state)
      expect(result).to be_nil
    end

    it "passes candidate through with warning note when LLM raises" do
      allow(planner).to receive(:run).and_raise(StandardError, "timeout")
      result = skeptic.review(valid_candidate, market_state)
      expect(result).not_to be_nil
      expect(result[:skeptic_notes]).to include("Skeptic unavailable")
    end
  end
end
