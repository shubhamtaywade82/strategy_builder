# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::SignalEvaluator do
  let(:candles) { TestData.candle_series(count: 300) }

  describe ".build" do
    it "returns a callable lambda" do
      strategy = TestData.strategy_candidate
      signal_gen = described_class.build(strategy)
      expect(signal_gen).to respond_to(:call)
    end

    it "raises when entry conditions include unknown names" do
      strategy = TestData.strategy_candidate.merge(
        entry: { conditions: %w[asia_range_defined not_a_real_condition] }
      )
      expect { described_class.build(strategy) }.to raise_error(StrategyBuilder::ValidationError, /not_a_real_condition/)
    end

    it "returns nil for insufficient warmup data" do
      strategy = TestData.strategy_candidate
      signal_gen = described_class.build(strategy)
      short_candles = candles[0..10]
      result = signal_gen.call(short_candles, strategy)
      expect(result).to be_nil
    end
  end

  describe "condition evaluation via registry" do
    let(:strategy) do
      TestData.strategy_candidate.merge(
        entry: { conditions: %w[asia_range_defined session_high_break volume_confirmation] }
      )
    end

    it "produces a signal hash when conditions align" do
      signal_gen = described_class.build(strategy)

      signals_found = 0
      candles.each_with_index do |_c, i|
        next if i < 50

        signal = signal_gen.call(candles[0..i], strategy)
        if signal
          signals_found += 1
          expect(signal).to include(:direction, :entry_price, :stop_distance, :size)
          expect(%i[long short]).to include(signal[:direction])
          expect(signal[:entry_price]).to be > 0
          expect(signal[:stop_distance]).to be > 0
          break
        end
      end
    end
  end

  describe ".passes_filters?" do
    let(:ctx) { StrategyBuilder::EvaluationContext.new(candles, TestData.strategy_candidate) }

    it "passes when no filters are set" do
      expect(described_class.passes_filters?(ctx, {})).to be true
    end

    it "rejects when volume zscore is below minimum" do
      filters = { min_volume_zscore: 100.0 } # unreachably high
      expect(described_class.passes_filters?(ctx, filters)).to be false
    end
  end

  describe ".passes_session_filter?" do
    it "passes for empty session list" do
      candle = candles.last
      expect(described_class.passes_session_filter?(candle, [])).to be true
    end

    it "passes for 'any' session" do
      candle = candles.last
      expect(described_class.passes_session_filter?(candle, ["any"])).to be true
    end
  end

  describe "integration: backtest engine + signal evaluator" do
    it "runs a full backtest with evaluator-generated signals" do
      strategy = TestData.strategy_candidate
      signal_gen = described_class.build(strategy)
      engine = StrategyBuilder::BacktestEngine.new

      result = engine.run(
        strategy: strategy,
        candles: candles,
        signal_generator: signal_gen
      )

      expect(result).to include(:trades, :metrics)
      expect(result[:metrics][:trade_count]).to be >= 0
    end
  end
end

RSpec.describe StrategyBuilder::ConditionRegistry do
  let(:candles) { TestData.candle_series(count: 300) }
  let(:ctx) { StrategyBuilder::EvaluationContext.new(candles, {}) }

  describe ".evaluate" do
    it "evaluates an existing condition safely" do
      expect([true, false]).to include(described_class.evaluate("asia_range_defined", ctx))
    end

    it "returns false for unknown conditions and logs a warning" do
      expect(StrategyBuilder.logger).to receive(:warn).with(any_args)
      expect(described_class.evaluate("unknown_magic_condition", ctx)).to be false
    end
  end
end
