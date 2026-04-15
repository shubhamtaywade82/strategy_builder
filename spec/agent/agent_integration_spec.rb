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

  describe "#run_with_llm_tools" do
    it "returns executor output when the tool loop completes" do
      loop = described_class.new
      executor = instance_double(Ollama::Agent::Executor)
      allow(loop).to receive(:build_executor).and_return(executor)
      allow(executor).to receive(:run).and_return("synthesis complete")

      out = loop.run_with_llm_tools(query: "research")

      expect(out[:final_result]).to eq("synthesis complete")
      expect(out[:steps].last).to include(type: :executor_result, content: "synthesis complete")
    end

    it "returns an error step when Executor raises Ollama::Error" do
      loop = described_class.new
      executor = instance_double(Ollama::Agent::Executor)
      allow(loop).to receive(:build_executor).and_return(executor)
      allow(executor).to receive(:run).and_raise(Ollama::Error.new("upstream failure"))

      out = loop.run_with_llm_tools(query: "research")

      expect(out[:final_result]).to be_nil
      expect(out[:steps]).to include(hash_including(type: :error, content: "upstream failure"))
    end

    it "raises when Executor is unavailable" do
      loop = described_class.new
      allow(loop).to receive(:build_executor).and_return(nil)

      expect { loop.run_with_llm_tools(query: "research") }.to raise_error(StrategyBuilder::Error, /Executor not available/)
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

RSpec.describe StrategyBuilder::ToolRegistry do
  describe "backtest_strategy tool" do
    it "uses SignalEvaluator for catalog backtests" do
      strategy = TestData.strategy_candidate
      entry = { id: "strat_123", strategy: strategy }
      candles = TestData.candle_series(count: 250)
      mtf = { "15m" => candles, "5m" => candles }
      signal_generator = lambda { |_candles_so_far, _strategy, *_mtf| nil }
      catalog = instance_double(StrategyBuilder::StrategyCatalog)
      loader = instance_double(StrategyBuilder::CandleLoader, fetch_mtf: mtf)
      walk_forward = instance_double(StrategyBuilder::WalkForward)
      walk_forward_result = {
        aggregate: { oos_expectancy: 0.15, oos_profit_factor: 1.4 },
        stability_score: 0.8,
        passes_walk_forward: true,
        folds: []
      }

      allow(StrategyBuilder::StrategyCatalog).to receive(:new).and_return(catalog)
      allow(catalog).to receive(:get).with("strat_123").and_return(entry)
      allow(catalog).to receive(:attach_backtest)
      allow(StrategyBuilder::SignalEvaluator).to receive(:build).with(strategy, mtf_candles: mtf).and_return(signal_generator)
      allow(StrategyBuilder::CandleLoader).to receive(:new).and_return(loader)
      allow(StrategyBuilder::WalkForward).to receive(:new).with(engine: an_instance_of(StrategyBuilder::BacktestEngine)).and_return(walk_forward)
      allow(walk_forward).to receive(:run).and_return(walk_forward_result)
      allow(walk_forward).to receive(:volatility_regime_slices).and_return({ segments: [], fraction_positive_expectancy: 0.5 })
      allow(walk_forward).to receive(:anchored_holdout).and_return(nil)
      allow(walk_forward).to receive(:session_analysis).and_return({})
      allow(StrategyBuilder::Robustness).to receive(:analyze).and_return({ robustness_score: 0.6, tested_params: 1 })

      result = described_class.new.fetch("backtest_strategy").callable.call(
        "strategy_id" => "strat_123",
        "instrument" => "B-BTC_USDT",
        "days_back" => 90,
        "folds" => 4
      )

      expect(StrategyBuilder::SignalEvaluator).to have_received(:build).with(strategy, mtf_candles: mtf)
      expect(catalog).to have_received(:attach_backtest).with(
        "strat_123",
        hash_including(metrics: walk_forward_result[:aggregate], walk_forward: walk_forward_result)
      )
      expect(result).to include(status: "backtested", passes: true)
    end
  end
end
