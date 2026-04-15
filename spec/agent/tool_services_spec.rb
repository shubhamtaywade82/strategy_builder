# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Agent::ToolServices::GenerateStrategies do
  describe ".call" do
    it "persists generated candidates to the catalog and returns their ids" do
      mtf = { "5m" => TestData.candle_series(count: 50) }
      features = { instrument: "B-BTC_USDT" }
      cand = TestData.strategy_candidate.merge(name: "ToolSvc Gen #{Time.now.to_f}")

      loader = instance_double(StrategyBuilder::CandleLoader, fetch_mtf: mtf)
      gen = instance_double(StrategyBuilder::StrategyGenerator, generate: [cand])

      allow(StrategyBuilder::CandleLoader).to receive(:new).and_return(loader)
      allow(StrategyBuilder::FeatureBuilder).to receive(:build).and_return(features)
      allow(StrategyBuilder::StrategyGenerator).to receive(:new).and_return(gen)

      rows = described_class.call(
        "instrument" => "B-BTC_USDT",
        "timeframes" => ["5m"],
        "days_back" => 7
      )

      expect(rows.size).to eq(1)
      expect(rows.first[:id]).to be_a(String).and(include("toolsvc"))

      fresh = StrategyBuilder::StrategyCatalog.new
      expect(fresh.get(rows.first[:id])[:strategy][:name]).to eq(cand[:name])
    end
  end
end

RSpec.describe StrategyBuilder::Agent::ToolServices::RankStrategies do
  describe ".call" do
    it "scores backtested entries and returns ranked rows" do
      wf = {
        aggregate: {
          oos_trade_count: 25,
          oos_expectancy: 0.2,
          oos_profit_factor: 1.3,
          avg_degradation: 0.2,
          oos_win_rate: 0.45,
          oos_max_drawdown: 0.05
        },
        stability_score: 0.75,
        passes_walk_forward: true,
        folds: []
      }

      catalog = StrategyBuilder::StrategyCatalog.new
      sid = catalog.add(TestData.strategy_candidate.merge(name: "Rank Tool #{Time.now.to_f}"))
      catalog.attach_backtest(sid, {
        metrics: wf[:aggregate],
        walk_forward: wf,
        instrument: "B-BTC_USDT",
        candle_count: 250
      })

      rows = described_class.call("limit" => 20)
      expect(rows).not_to be_empty
      reloaded = StrategyBuilder::StrategyCatalog.new.get(sid)
      expect(reloaded[:ranking]).to be_a(Hash)
      expect(reloaded[:ranking]).to include(:final_score, :status)
    end
  end
end
