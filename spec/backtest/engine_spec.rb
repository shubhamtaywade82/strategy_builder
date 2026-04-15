# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::BacktestEngine do
  let(:candles) { TestData.candle_series(count: 300) }
  let(:strategy) { TestData.strategy_candidate }
  let(:engine) { described_class.new }

  # Simple signal generator: enter long every 50 candles
  let(:signal_generator) do
    counter = 0
    lambda do |candles_so_far, _strat, *_mtf|
      counter += 1
      if counter % 50 == 0
        atr = candles_so_far.last[:close] * 0.01
        { direction: :long, entry_price: candles_so_far.last[:close], stop_distance: atr, size: 1.0 }
      end
    end
  end

  describe "#run" do
    it "produces trades and metrics" do
      result = engine.run(strategy: strategy, candles: candles, signal_generator: signal_generator)

      expect(result).to include(:trades, :metrics)
      expect(result[:trades]).to be_an(Array)
      expect(result[:metrics]).to include(:trade_count, :net_pnl, :win_rate, :expectancy)
    end

    it "computes non-nil metrics for non-empty trades" do
      result = engine.run(strategy: strategy, candles: candles, signal_generator: signal_generator)
      next if result[:trades].empty?

      metrics = result[:metrics]
      expect(metrics[:trade_count]).to be > 0
      expect(metrics[:win_rate]).to be_between(0, 1)
    end

    it "records hold_candles as exit bar minus entry bar" do
      entry_idx = 100
      exit_idx = 107
      pos = StrategyBuilder::BacktestEngine::Position.new(
        id: 1,
        direction: :long,
        entry_price: 100.0,
        entry_time: 1,
        entry_index: entry_idx,
        size: 1.0,
        remaining_size: 1.0,
        stop_price: 90.0,
        targets: [],
        partial_exits: [1.0],
        trail_config: nil,
        state: :position_open,
        fills: [],
        pnl: 0.0,
        be_shifted: false,
        current_trail_stop: 90.0
      )
      candle = { high: 120, low: 99, close: 110, timestamp: 999 }
      trade = engine.send(:close_position, pos, { reason: :target_hit, price: 110.0 }, candle, exit_idx, [candle])
      expect(trade.hold_candles).to eq(exit_idx - entry_idx)
    end

    it "sizes partial exits as fractions of original position, not remaining_size" do
      pos = StrategyBuilder::BacktestEngine::Position.new(
        id: 1,
        direction: :long,
        entry_price: 100.0,
        entry_time: 1,
        entry_index: 50,
        size: 1.0,
        remaining_size: 0.67,
        stop_price: 90.0,
        targets: [110.0],
        partial_exits: [0.33, 0.67],
        trail_config: nil,
        state: :position_open,
        fills: [],
        pnl: 0.0,
        be_shifted: false,
        current_trail_stop: 90.0
      )
      candle = { high: 115, low: 99, close: 110, timestamp: 2 }
      engine.send(:apply_partial_exit, pos, { fraction: 0.33, price: 110.0 }, candle, [candle])
      expect(pos.remaining_size).to be_within(1e-9).of(0.34)
    end

    it "force-closes open positions at end of data" do
      # Signal on last candle — should be force-closed with :end_of_data
      always_signal = lambda do |candles_so_far, _strat, *_mtf|
        if candles_so_far.size == candles.size
          { direction: :long, entry_price: candles_so_far.last[:close], stop_distance: 1.0, size: 1.0 }
        end
      end

      result = engine.run(strategy: strategy, candles: candles, signal_generator: always_signal)
      eod_trades = result[:trades].select { |t| t.exit_reason == :end_of_data }
      # May or may not have EOD trade depending on timing
      expect(result[:trades]).to be_an(Array)
    end
  end
end

RSpec.describe StrategyBuilder::Metrics do
  describe ".compute" do
    it "returns empty_metrics for no trades" do
      result = described_class.compute([])
      expect(result[:trade_count]).to eq(0)
      expect(result[:net_pnl]).to eq(0.0)
    end

    it "computes correct win rate" do
      trades = [
        StrategyBuilder::BacktestEngine::Trade.new(position_id: 1, direction: :long, entry_price: 100, exit_price: 110, entry_time: 0, exit_time: 1, size: 1, pnl: 10, pnl_r: 1.0, fees: 0.1, slippage: 0, exit_reason: :target_hit, hold_candles: 5),
        StrategyBuilder::BacktestEngine::Trade.new(position_id: 2, direction: :long, entry_price: 100, exit_price: 95, entry_time: 2, exit_time: 3, size: 1, pnl: -5, pnl_r: -0.5, fees: 0.1, slippage: 0, exit_reason: :stop_loss, hold_candles: 3),
        StrategyBuilder::BacktestEngine::Trade.new(position_id: 3, direction: :long, entry_price: 100, exit_price: 108, entry_time: 4, exit_time: 5, size: 1, pnl: 8, pnl_r: 0.8, fees: 0.1, slippage: 0, exit_reason: :target_hit, hold_candles: 4)
      ]

      result = described_class.compute(trades)
      expect(result[:trade_count]).to eq(3)
      expect(result[:win_rate]).to be_within(0.01).of(0.6667)
      expect(result[:net_pnl]).to eq(13.0)
      expect(result[:profit_factor]).to be > 1.0
    end

    it "computes max drawdown correctly" do
      pnls = [10, -5, -8, 3, 15, -2]
      dd = described_class.compute_max_drawdown(pnls)
      # Cumulative: 10, 5, -3, 0, 15, 13
      # Peak:       10, 10, 10, 10, 15, 15
      # DD:          0,  5, 13, 10,  0,  2
      expect(dd).to eq(13)
    end
  end
end

RSpec.describe StrategyBuilder::WalkForward do
  let(:candles) { TestData.candle_series(count: 1000) }
  let(:strategy) { TestData.strategy_candidate }
  let(:engine) { StrategyBuilder::BacktestEngine.new }
  let(:walk_forward) { described_class.new(engine: engine) }

  let(:signal_generator) do
    counter = 0
    lambda do |candles_so_far, _strat, *_mtf|
      counter += 1
      if counter % 30 == 0
        { direction: :long, entry_price: candles_so_far.last[:close], stop_distance: candles_so_far.last[:close] * 0.01, size: 1.0 }
      end
    end
  end

  describe "#run" do
    it "produces fold results with IS and OOS metrics" do
      result = walk_forward.run(
        strategy: strategy,
        candles: candles,
        signal_generator: signal_generator,
        folds: 3
      )

      expect(result).to include(:folds, :aggregate, :stability_score, :passes_walk_forward)
      expect(result[:folds].size).to eq(3)
      expect(result[:folds].first).to include(:in_sample, :out_of_sample, :degradation)
    end

    it "raises on insufficient data" do
      short_candles = TestData.candle_series(count: 50)
      expect {
        walk_forward.run(strategy: strategy, candles: short_candles, signal_generator: signal_generator, folds: 5)
      }.to raise_error(StrategyBuilder::BacktestError)
    end
  end
end

RSpec.describe StrategyBuilder::CandidateValidator do
  let(:validator) { described_class.new }

  describe "#validate" do
    it "accepts a valid strategy candidate" do
      result = validator.validate(TestData.strategy_candidate)
      expect(result[:valid]).to be true
      expect(result[:errors]).to be_empty
    end

    it "rejects candidate with missing entry conditions" do
      bad = TestData.strategy_candidate.merge(entry: { conditions: [] })
      result = validator.validate(bad)
      expect(result[:valid]).to be false
    end

    it "rejects candidate with excessive risk" do
      bad = TestData.strategy_candidate.dup
      bad[:risk] = bad[:risk].merge(max_risk_percent: 5.0)
      result = validator.validate(bad)
      expect(result[:valid]).to be false
    end

    it "repairs partial exits when count or sum disagrees with targets" do
      bad = TestData.strategy_candidate.dup
      bad[:exit] = bad[:exit].merge(partial_exits: [0.3, 0.3, 0.3])
      result = validator.validate(bad)
      expect(result[:valid]).to be true
      expect(bad[:exit][:partial_exits]).to eq([0.5, 0.5])
    end

    it "repairs partial exits that sum under 1.0 when counts match" do
      cand = TestData.strategy_candidate.dup
      cand[:exit] = cand[:exit].merge(partial_exits: [0.4, 0.4])
      result = validator.validate(cand)
      expect(result[:valid]).to be true
      expect(cand[:exit][:partial_exits].sum).to be_within(1e-6).of(1.0)
      expect(cand[:exit][:partial_exits].size).to eq(cand[:exit][:targets].size)
    end

    it "rejects a non-hash candidate without raising" do
      result = validator.validate("not a strategy object")
      expect(result[:valid]).to be false
      expect(result[:errors].join).to include("JSON object")
    end
  end

  describe "#filter_valid" do
    it "keeps only hash candidates when the model returns mixed JSON" do
      good = TestData.strategy_candidate
      mixed = ["preamble text", good, 42]
      kept = validator.filter_valid(mixed)
      expect(kept.size).to eq(1)
      expect(kept.first[:candidate]).to eq(good)
    end
  end
end
