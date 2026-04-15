# frozen_string_literal: true

require "spec_helper"

RSpec.describe "public require paths" do
  {
    "strategy_builder/backtest/signal_evaluator" => StrategyBuilder::SignalEvaluator,
    "strategy_builder/market_data/candle_store" => StrategyBuilder::CandleStore,
    "strategy_builder/strategy_builder/candidate_validator" => StrategyBuilder::CandidateValidator,
    "strategy_builder/backtest/slippage_model" => StrategyBuilder::SlippageModel,
    "strategy_builder/backtest/fee_model" => StrategyBuilder::FeeModel,
    "strategy_builder/backtest/partial_exit_model" => StrategyBuilder::PartialExitModel,
    "strategy_builder/backtest/trailing_model" => StrategyBuilder::TrailingModel,
    "strategy_builder/ranking/gatekeeper" => StrategyBuilder::Gatekeeper,
    "strategy_builder/ranking/robustness" => StrategyBuilder::Robustness,
    "strategy_builder/documentation/markdown_exporter" => StrategyBuilder::MarkdownExporter,
    "strategy_builder/documentation/json_exporter" => StrategyBuilder::JsonExporter
  }.each do |path, constant|
    it "loads #{path}" do
      expect { require path }.not_to raise_error
      expect(constant).to be_a(Class)
    end
  end
end
