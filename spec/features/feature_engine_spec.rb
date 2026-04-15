# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::VolatilityProfile do
  let(:candles) { TestData.candle_series(count: 200) }

  describe ".atr" do
    it "computes ATR series aligned to candle count" do
      atr = described_class.atr(candles)
      expect(atr.size).to eq(candles.size)
    end

    it "returns nil for early candles before warmup" do
      atr = described_class.atr(candles, period: 14)
      expect(atr[0..13]).to all(be_nil)
    end

    it "produces positive ATR values after warmup" do
      atr = described_class.atr(candles, period: 14)
      expect(atr.compact).to all(be > 0)
    end
  end

  describe ".regime" do
    it "returns a valid regime symbol" do
      regime = described_class.regime(candles)
      expect(%i[compression normal expansion unknown]).to include(regime)
    end
  end

  describe ".profile" do
    it "returns a hash with required keys" do
      profile = described_class.profile(candles)
      expect(profile).to include(:current_atr, :current_atr_percent, :regime, :range_expansion_last)
    end
  end
end

RSpec.describe StrategyBuilder::StructureDetector do
  let(:candles) { TestData.candle_series(count: 200) }

  describe ".swing_points" do
    it "detects swing highs and lows" do
      sp = described_class.swing_points(candles)
      expect(sp).to include(:highs, :lows)
      expect(sp[:highs]).to be_an(Array)
      expect(sp[:lows]).to be_an(Array)
    end

    it "returns swing points with price and index" do
      sp = described_class.swing_points(candles)
      next if sp[:highs].empty?

      expect(sp[:highs].first).to include(:index, :price, :timestamp)
    end
  end

  describe ".structure" do
    it "returns a valid structure classification" do
      structure = described_class.structure(candles)
      expect(%i[bullish bearish ranging unknown]).to include(structure)
    end
  end

  describe ".profile" do
    it "returns complete profile hash" do
      profile = described_class.profile(candles)
      expect(profile).to include(:structure, :swing_highs, :swing_lows, :breakout_signals)
    end
  end
end

RSpec.describe StrategyBuilder::MomentumEngine do
  let(:candles) { TestData.candle_series(count: 200) }

  describe ".ema" do
    it "computes EMA values" do
      closes = candles.map { |c| c[:close] }
      ema = described_class.ema(closes, period: 20)
      expect(ema.compact.size).to be > 0
    end
  end

  describe ".rsi" do
    it "returns RSI values between 0 and 100" do
      rsi = described_class.rsi(candles)
      valid = rsi.compact
      expect(valid).to all(be_between(0, 100))
    end
  end

  describe ".macd" do
    it "returns macd, signal, and histogram arrays" do
      result = described_class.macd(candles)
      expect(result).to include(:macd, :signal, :histogram)
    end
  end

  describe ".profile" do
    it "returns momentum profile with all indicators" do
      profile = described_class.profile(candles)
      expect(profile).to include(:rsi_current, :rsi_zone, :macd_histogram, :macd_crossover)
    end
  end
end

RSpec.describe StrategyBuilder::VolumeProfile do
  let(:candles) { TestData.candle_series(count: 200) }

  describe ".relative_volume" do
    it "produces values relative to rolling average" do
      rvol = described_class.relative_volume(candles)
      expect(rvol.compact.size).to be > 0
    end

    it "aligns one value per candle index using the prior window only (no extra leading value)" do
      lookback = 3
      vols = [100.0, 100.0, 100.0, 300.0] + [100.0] * 10
      bars = vols.each_with_index.map do |v, i|
        TestData.candle(timestamp: i, volume: v, open: 1, high: 2, low: 0.5, close: 1.5)
      end
      rvol = described_class.relative_volume(bars, lookback: lookback)
      expect(rvol.size).to eq(bars.size)
      expect(rvol[0..(lookback - 1)]).to all(be_nil)
      baseline = (100.0 + 100.0 + 100.0) / 3.0
      expect(rvol[lookback]).to eq(300.0 / baseline)
    end
  end

  describe ".volume_zscore" do
    it "produces z-score values" do
      zscores = described_class.volume_zscore(candles)
      expect(zscores.compact.size).to be > 0
    end

    it "returns one entry per candle and scores the final bar" do
      lookback = 3
      bars = (0..6).map do |i|
        TestData.candle(timestamp: i, volume: 100.0 + i, open: 1, high: 2, low: 0.5, close: 1.5)
      end
      z = described_class.volume_zscore(bars, lookback: lookback)
      expect(z.size).to eq(bars.size)
      expect(z.last).not_to be_nil
    end
  end

  describe ".vwap" do
    it "computes VWAP series" do
      vwap = described_class.vwap(candles)
      expect(vwap.size).to eq(candles.size)
      expect(vwap.last).to be > 0
    end
  end
end

RSpec.describe StrategyBuilder::SessionDetector do
  let(:candles) { TestData.candle_series(count: 200) }

  describe ".tag_candles" do
    it "adds sessions key to each candle" do
      tagged = described_class.tag_candles(candles)
      expect(tagged.first).to include(:sessions)
      expect(tagged.first[:sessions]).to be_an(Array)
    end
  end

  describe ".detect_sessions" do
    it "returns unique session names" do
      sessions = described_class.detect_sessions(candles)
      expect(sessions).to be_an(Array)
    end
  end
end

RSpec.describe StrategyBuilder::FeatureBuilder do
  let(:mtf_candles) { TestData.mtf_candles }

  describe ".build" do
    it "produces a complete feature hash" do
      features = described_class.build(instrument: "B-BTC_USDT", mtf_candles: mtf_candles)
      expect(features).to include(:instrument, :mtf_alignment, :volatility, :structure, :volume, :momentum)
    end

    it "raises DataError for empty candles" do
      expect { described_class.build(instrument: "X", mtf_candles: {}) }
        .to raise_error(StrategyBuilder::DataError)
    end
  end
end
