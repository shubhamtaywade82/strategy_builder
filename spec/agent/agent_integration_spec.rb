# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::AgentLoop do
  describe "#run" do
    it "runs the deterministic manual pipeline" do
      loop = described_class.new
      allow(loop).to receive(:run_manual_pipeline).with("research").and_return([{ type: :manual_done }])

      out = loop.run(query: "research")

      expect(out[:final_result]).to be_nil
      expect(out[:steps]).to include(type: :manual_done)
      expect(loop).to have_received(:run_manual_pipeline).with("research")
    end
  end

  describe "#propose" do
    it "does not add the same strategy twice when discovery covers multiple instruments" do
      gen = instance_double(StrategyBuilder::StrategyGenerator)
      allow(StrategyBuilder::StrategyGenerator).to receive(:new).and_return(gen)
      dup = TestData.strategy_candidate.merge(name: "Shared Strategy", family: "session_breakout")
      allow(gen).to receive(:generate).and_return([dup])

      loop = described_class.new
      features_by_instrument = {
        "B-BTC_USDT" => { instrument: "B-BTC_USDT" },
        "B-ETH_USDT" => { instrument: "B-ETH_USDT" }
      }

      out = loop.propose(features_by_instrument: features_by_instrument)

      expect(out.size).to eq(1)
      expect(StrategyBuilder::StrategyCatalog.new.size).to eq(1)
    end
  end

  describe "#validate" do
    it "builds backtest signals through SignalEvaluator" do
      strategy = TestData.strategy_candidate
      catalog = StrategyBuilder::StrategyCatalog.new
      strategy_id = catalog.add(strategy)
      candles = TestData.candle_series(count: 250)
      mtf = { "15m" => candles, "5m" => candles }
      signal_generator = lambda { |_candles_so_far, _strategy, *_mtf| nil }
      loader = instance_double(StrategyBuilder::CandleLoader, fetch_mtf: mtf)
      walk_forward = instance_double(StrategyBuilder::WalkForward)
      walk_forward_result = {
        aggregate: { oos_expectancy: 0.12, oos_profit_factor: 1.3 },
        stability_score: 0.7,
        passes_walk_forward: true,
        folds: []
      }

      allow(StrategyBuilder::SignalEvaluator).to receive(:build).with(strategy, mtf_candles: mtf).and_return(signal_generator)
      allow(StrategyBuilder::CandleLoader).to receive(:new).and_return(loader)
      allow(StrategyBuilder::WalkForward).to receive(:new).with(engine: an_instance_of(StrategyBuilder::BacktestEngine)).and_return(walk_forward)
      allow(walk_forward).to receive(:run).and_return(walk_forward_result)
      allow(walk_forward).to receive(:volatility_regime_slices).and_return({ segments: [], fraction_positive_expectancy: 0.5 })
      allow(walk_forward).to receive(:anchored_holdout).and_return(nil)
      allow(walk_forward).to receive(:session_analysis).and_return({})
      allow(StrategyBuilder::Robustness).to receive(:analyze).and_return({ robustness_score: 0.7, tested_params: 1 })

      described_class.new.validate(catalog: catalog, instruments: ["B-BTC_USDT"], days_back: 90)

      expect(StrategyBuilder::SignalEvaluator).to have_received(:build).with(strategy, mtf_candles: mtf)
      expect(catalog.get(strategy_id).dig(:backtest_results, :walk_forward)).to eq(walk_forward_result)
    end
  end
end
