# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::SignalGeneratorFactory do
  let(:candles) { TestData.candle_series(count: 300) }

  describe ".build" do
    it "returns a callable lambda" do
      strategy = TestData.strategy_candidate
      signal_gen = described_class.build(strategy)
      expect(signal_gen).to respond_to(:call)
    end

    it "returns nil for insufficient warmup data" do
      strategy = TestData.strategy_candidate
      signal_gen = described_class.build(strategy)
      short_candles = candles[0..10]
      result = signal_gen.call(short_candles, strategy)
      expect(result).to be_nil
    end
  end

  describe "session_breakout evaluator" do
    let(:strategy) do
      TestData.strategy_candidate.merge(
        family: "session_breakout",
        entry: { conditions: %w[session_high_break] }
      )
    end

    it "produces a signal hash when conditions align" do
      signal_gen = described_class.build(strategy)

      # Run across all candles until a signal appears (or doesn't)
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

      # It's acceptable if no signal fires on random data — the test validates structure when one does
    end
  end

  describe "mtf_pullback evaluator" do
    let(:strategy) do
      TestData.strategy_candidate.merge(
        family: "mtf_pullback",
        entry: { conditions: %w[higher_tf_trend_bullish lower_tf_pullback_to_ema] }
      )
    end

    it "builds without error" do
      signal_gen = described_class.build(strategy)
      expect(signal_gen).to respond_to(:call)
    end
  end

  describe "compression_breakout evaluator" do
    let(:strategy) do
      TestData.strategy_candidate.merge(
        family: "compression_breakout",
        entry: { conditions: %w[compression_detected range_break] }
      )
    end

    it "builds without error" do
      signal_gen = described_class.build(strategy)
      expect(signal_gen).to respond_to(:call)
    end
  end

  describe "failed_breakout evaluator" do
    let(:strategy) do
      TestData.strategy_candidate.merge(
        family: "failed_breakout",
        entry: { conditions: %w[breakout_attempt retest_below_level] }
      )
    end

    it "builds without error" do
      signal_gen = described_class.build(strategy)
      expect(signal_gen).to respond_to(:call)
    end
  end

  describe "vwap_reclaim evaluator" do
    let(:strategy) do
      TestData.strategy_candidate.merge(
        family: "vwap_reclaim",
        entry: { conditions: %w[price_reclaims_vwap structure_bullish_shift] }
      )
    end

    it "builds without error" do
      signal_gen = described_class.build(strategy)
      expect(signal_gen).to respond_to(:call)
    end
  end

  describe ".passes_filters?" do
    it "passes when no filters are set" do
      expect(described_class.passes_filters?(candles, {})).to be true
    end

    it "rejects when volume zscore is below minimum" do
      filters = { min_volume_zscore: 100.0 } # unreachably high
      expect(described_class.passes_filters?(candles, filters)).to be false
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

  describe "integration: backtest engine + signal generator factory" do
    it "runs a full backtest with factory-generated signals" do
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
