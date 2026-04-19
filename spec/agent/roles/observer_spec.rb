# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Agent::Roles::Observer do
  let(:client)   { instance_double(Ollama::Client) }
  let(:planner)  { instance_double(StrategyBuilder::OllamaGeneratePlanner) }
  let(:observer) { described_class.new(client: client) }

  let(:market_state) do
    StrategyBuilder::State::MarketState.new(
      instrument:        "B-BTC_USDT",
      snapshot_at:       Time.utc(2024, 1, 15, 10, 0),
      primary_timeframe: "5m",
      regime:            :compression,
      session:           :london,
      higher_tf_bias:    :bullish,
      mid_tf_structure:  :ranging,
      lower_tf_state:    :compressing,
      volatility:        :contracting,
      volume:            :average,
      liquidity:         { equal_highs: [], equal_lows: [], nearest_resist: nil, nearest_support: nil },
      bias:              :long,
      raw_features:      {}
    )
  end

  before do
    allow(StrategyBuilder::OllamaGeneratePlanner).to receive(:build).with(client).and_return(planner)
  end

  describe "#classify" do
    let(:llm_response) do
      {
        "narrative"        => "Price compressing near session highs with bullish HTF.",
        "session_context"  => "London session open.",
        "key_levels"       => ["42500 — prior day high", "42000 — session low"],
        "no_trade_context" => []
      }
    end

    before do
      allow(planner).to receive(:run).and_return(llm_response)
    end

    it "returns a hash with confirmed_regime from MarketState (not LLM)" do
      result = observer.classify(market_state)
      expect(result[:confirmed_regime]).to eq(:compression)
    end

    it "includes LLM narrative" do
      result = observer.classify(market_state)
      expect(result[:narrative]).to eq("Price compressing near session highs with bullish HTF.")
    end

    it "includes key_levels as array" do
      result = observer.classify(market_state)
      expect(result[:key_levels]).to be_an(Array)
      expect(result[:key_levels].size).to eq(2)
    end

    it "includes no_trade_context as array" do
      result = observer.classify(market_state)
      expect(result[:no_trade_context]).to be_an(Array)
    end

    it "falls back gracefully when LLM raises" do
      allow(planner).to receive(:run).and_raise(StandardError, "timeout")
      result = observer.classify(market_state)
      expect(result[:confirmed_regime]).to eq(:compression)
      expect(result[:narrative]).to eq("")
    end
  end
end
