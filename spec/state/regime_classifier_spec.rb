# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::State::RegimeClassifier do
  def features(vol:, structure:, aligned_bull: false, aligned_bear: false)
    {
      volatility: { regime: vol },
      structure:  { structure: structure },
      mtf_alignment: {
        alignment: {
          aligned_bullish: aligned_bull,
          aligned_bearish: aligned_bear,
          regime: aligned_bull ? :strong_bullish : (aligned_bear ? :strong_bearish : :neutral)
        }
      }
    }
  end

  it "returns :compression when volatility is compression" do
    expect(described_class.classify(features(vol: :compression, structure: :bullish))).to eq(:compression)
  end

  it "returns :trend_up for expansion + bullish + aligned" do
    expect(described_class.classify(features(vol: :expansion, structure: :bullish, aligned_bull: true))).to eq(:trend_up)
  end

  it "returns :trend_down for expansion + bearish + aligned" do
    expect(described_class.classify(features(vol: :expansion, structure: :bearish, aligned_bear: true))).to eq(:trend_down)
  end

  it "returns :expansion for expansion + ranging" do
    expect(described_class.classify(features(vol: :expansion, structure: :ranging))).to eq(:expansion)
  end

  it "returns :trend_up for normal + bullish + aligned" do
    expect(described_class.classify(features(vol: :normal, structure: :bullish, aligned_bull: true))).to eq(:trend_up)
  end

  it "returns :trend_down for normal + bearish + aligned" do
    expect(described_class.classify(features(vol: :normal, structure: :bearish, aligned_bear: true))).to eq(:trend_down)
  end

  it "returns :range for normal + ranging" do
    expect(described_class.classify(features(vol: :normal, structure: :ranging))).to eq(:range)
  end

  it "returns :chop for normal + bullish but not aligned" do
    expect(described_class.classify(features(vol: :normal, structure: :bullish, aligned_bull: false))).to eq(:chop)
  end

  it "returns :chop for unknown volatility" do
    expect(described_class.classify(features(vol: :unknown, structure: :bullish))).to eq(:chop)
  end
end
