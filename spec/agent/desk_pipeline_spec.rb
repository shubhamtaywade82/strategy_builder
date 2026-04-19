# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Agent::DeskPipeline do
  let(:client) { instance_double(Ollama::Client) }
  let(:observer)        { instance_double(StrategyBuilder::Agent::Roles::Observer) }
  let(:pattern_analyst) { instance_double(StrategyBuilder::Agent::Roles::PatternAnalyst) }
  let(:trade_designer)  { instance_double(StrategyBuilder::Agent::Roles::TradeDesigner) }
  let(:skeptic)         { instance_double(StrategyBuilder::Agent::Roles::Skeptic) }

  let(:features) do
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
          aligned_bullish: true,
          aligned_bearish: false,
          regime:          :strong_bullish
        }
      },
      volume: { volume_zscore: 1.2 },
      per_timeframe_summary: {}
    }
  end

  let(:candidate) { TestData.strategy_candidate }
  let(:accepted)  { candidate.merge(skeptic_notes: []) }

  before do
    allow(StrategyBuilder::Agent::Roles::Observer).to receive(:new).and_return(observer)
    allow(StrategyBuilder::Agent::Roles::PatternAnalyst).to receive(:new).and_return(pattern_analyst)
    allow(StrategyBuilder::Agent::Roles::TradeDesigner).to receive(:new).and_return(trade_designer)
    allow(StrategyBuilder::Agent::Roles::Skeptic).to receive(:new).and_return(skeptic)

    allow(observer).to receive(:classify).and_return({
      confirmed_regime: :compression, narrative: "test", session_context: "", key_levels: [], no_trade_context: []
    })
    allow(pattern_analyst).to receive(:analyze).and_return([
      { name: :compression_breakout, score: 0.8, trigger: "breakout of range high", continuation: true }
    ])
    allow(trade_designer).to receive(:synthesize).and_return([candidate])
    allow(skeptic).to receive(:review).and_return(accepted)
  end

  describe "#run" do
    subject(:pipeline) { described_class.new(client: client) }

    it "returns an array of accepted candidates" do
      result = pipeline.run(instrument: "B-BTC_USDT", features: features)
      expect(result).to be_an(Array)
      expect(result.first).to include(:name)
    end

    it "calls all 4 roles in order" do
      pipeline.run(instrument: "B-BTC_USDT", features: features)
      expect(observer).to have_received(:classify)
      expect(pattern_analyst).to have_received(:analyze)
      expect(trade_designer).to have_received(:synthesize)
      expect(skeptic).to have_received(:review)
    end

    it "returns empty when skeptic rejects all" do
      allow(skeptic).to receive(:review).and_return(nil)
      result = pipeline.run(instrument: "B-BTC_USDT", features: features)
      expect(result).to be_empty
    end

    it "passes market_state to Observer" do
      pipeline.run(instrument: "B-BTC_USDT", features: features)
      expect(observer).to have_received(:classify).with(an_instance_of(StrategyBuilder::State::MarketState))
    end
  end
end
