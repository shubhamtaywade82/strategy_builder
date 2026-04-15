# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::AgentLoop do
  describe "#validate" do
    it "builds backtest signals through SignalGeneratorFactory" do
      strategy = TestData.strategy_candidate
      catalog = StrategyBuilder::StrategyCatalog.new
      strategy_id = catalog.add(strategy)
      candles = TestData.candle_series(count: 250)
      signal_generator = lambda { |_candles_so_far, _strategy| nil }
      loader = instance_double(StrategyBuilder::CandleLoader, fetch: candles)
      walk_forward = instance_double(StrategyBuilder::WalkForward)
      walk_forward_result = {
        aggregate: { oos_expectancy: 0.12, oos_profit_factor: 1.3 },
        stability_score: 0.7,
        passes_walk_forward: true,
        folds: []
      }

      allow(StrategyBuilder::SignalGeneratorFactory).to receive(:build).with(strategy).and_return(signal_generator)
      allow(StrategyBuilder::CandleLoader).to receive(:new).and_return(loader)
      allow(StrategyBuilder::WalkForward).to receive(:new).with(engine: an_instance_of(StrategyBuilder::BacktestEngine)).and_return(walk_forward)
      allow(walk_forward).to receive(:run).with(
        strategy: strategy,
        candles: candles,
        signal_generator: signal_generator
      ).and_return(walk_forward_result)

      described_class.new.validate(catalog: catalog, instruments: ["B-BTC_USDT"], days_back: 90)

      expect(StrategyBuilder::SignalGeneratorFactory).to have_received(:build).with(strategy)
      expect(catalog.get(strategy_id).dig(:backtest_results, :walk_forward)).to eq(walk_forward_result)
    end
  end
end

RSpec.describe StrategyBuilder::ToolRegistry do
  describe "backtest_strategy tool" do
    it "uses SignalGeneratorFactory for catalog backtests" do
      strategy = TestData.strategy_candidate
      entry = { id: "strat_123", strategy: strategy }
      candles = TestData.candle_series(count: 250)
      signal_generator = lambda { |_candles_so_far, _strategy| nil }
      catalog = instance_double(StrategyBuilder::StrategyCatalog)
      loader = instance_double(StrategyBuilder::CandleLoader, fetch: candles)
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
      allow(StrategyBuilder::SignalGeneratorFactory).to receive(:build).with(strategy).and_return(signal_generator)
      allow(StrategyBuilder::CandleLoader).to receive(:new).and_return(loader)
      allow(StrategyBuilder::WalkForward).to receive(:new).with(engine: an_instance_of(StrategyBuilder::BacktestEngine)).and_return(walk_forward)
      allow(walk_forward).to receive(:run).with(
        strategy: strategy,
        candles: candles,
        signal_generator: signal_generator,
        folds: 4
      ).and_return(walk_forward_result)

      result = described_class.new.fetch("backtest_strategy").callable.call(
        "strategy_id" => "strat_123",
        "instrument" => "B-BTC_USDT",
        "days_back" => 90,
        "folds" => 4
      )

      expect(StrategyBuilder::SignalGeneratorFactory).to have_received(:build).with(strategy)
      expect(catalog).to have_received(:attach_backtest).with(
        "strat_123",
        hash_including(metrics: walk_forward_result[:aggregate], walk_forward: walk_forward_result)
      )
      expect(result).to include(status: "backtested", passes: true)
    end
  end
end
