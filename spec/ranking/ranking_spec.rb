# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Scorer do
  let(:good_walk_forward) do
    {
      aggregate: {
        oos_expectancy: 0.25,
        oos_win_rate: 0.55,
        oos_profit_factor: 1.8,
        oos_max_drawdown: 0.15,
        oos_avg_r: 0.4,
        oos_trade_count: 80
      },
      stability_score: 0.8
    }
  end

  let(:poor_walk_forward) do
    {
      aggregate: {
        oos_expectancy: -0.05,
        oos_win_rate: 0.35,
        oos_profit_factor: 0.7,
        oos_max_drawdown: 0.5,
        oos_avg_r: -0.2,
        oos_trade_count: 15
      },
      stability_score: 0.2
    }
  end

  describe ".score" do
    it "produces higher scores for better strategies" do
      good_score = described_class.score(walk_forward_result: good_walk_forward)
      poor_score = described_class.score(walk_forward_result: poor_walk_forward)

      expect(good_score[:final_score]).to be > poor_score[:final_score]
    end

    it "returns component scores" do
      result = described_class.score(walk_forward_result: good_walk_forward)
      expect(result[:component_scores]).to include(
        :expectancy, :profit_factor, :oos_stability, :drawdown_resilience
      )
    end
  end
end

RSpec.describe StrategyBuilder::Gatekeeper do
  describe ".evaluate" do
    it "passes strategies that clear all gates" do
      wf = {
        aggregate: {
          oos_expectancy: 0.2,
          oos_win_rate: 0.5,
          oos_profit_factor: 1.5,
          oos_max_drawdown: 0.1,
          oos_trade_count: 50,
          avg_degradation: 0.3
        },
        stability_score: 0.8
      }

      result = described_class.evaluate(walk_forward_result: wf)
      expect(result[:status]).to eq("pass")
      expect(result[:failures]).to be_empty
    end

    it "rejects strategies with negative expectancy" do
      wf = {
        aggregate: {
          oos_expectancy: -0.1,
          oos_win_rate: 0.4,
          oos_profit_factor: 0.8,
          oos_max_drawdown: 0.3,
          oos_trade_count: 50,
          avg_degradation: 0.5
        },
        stability_score: 0.6
      }

      result = described_class.evaluate(walk_forward_result: wf)
      expect(result[:status]).not_to eq("pass")
      expect(result[:failures]).to include(a_string_matching(/expectancy/i))
    end

    it "rejects strategies with too few trades" do
      wf = {
        aggregate: {
          oos_expectancy: 0.5,
          oos_win_rate: 0.7,
          oos_profit_factor: 3.0,
          oos_max_drawdown: 0.05,
          oos_trade_count: 5,
          avg_degradation: 0.1
        },
        stability_score: 0.9
      }

      result = described_class.evaluate(walk_forward_result: wf)
      expect(result[:failures]).to include(a_string_matching(/trades/i))
    end
  end
end

RSpec.describe StrategyBuilder::StrategyCatalog do
  let(:catalog) { described_class.new(storage_dir: Dir.mktmpdir) }
  let(:candidate) { TestData.strategy_candidate }

  describe "#add" do
    it "adds a strategy and returns an id" do
      id = catalog.add(candidate)
      expect(id).to be_a(String)
      expect(id).not_to be_empty
    end
  end

  describe "#get" do
    it "retrieves the added strategy" do
      id = catalog.add(candidate)
      entry = catalog.get(id)
      expect(entry[:strategy][:name]).to eq(candidate[:name])
      expect(entry[:status]).to eq("proposed")
    end
  end

  describe "#update_status" do
    it "changes strategy status" do
      id = catalog.add(candidate)
      catalog.update_status(id, "validated")
      expect(catalog.get(id)[:status]).to eq("validated")
    end

    it "rejects unknown statuses" do
      id = catalog.add(candidate)
      expect { catalog.update_status(id, "invalid_status") }
        .to raise_error(StrategyBuilder::ValidationError)
    end
  end

  describe "#by_status" do
    it "filters by status" do
      catalog.add(candidate, status: "proposed")
      catalog.add(candidate.merge(name: "Another"), status: "pass")

      proposed = catalog.by_status("proposed")
      expect(proposed.size).to eq(1)
    end
  end
end
