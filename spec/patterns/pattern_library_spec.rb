# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Patterns::PatternLibrary do
  describe ".all" do
    it "returns a hash of patterns" do
      expect(described_class.all).to be_a(Hash)
      expect(described_class.all).not_to be_empty
    end

    it "includes all known pattern families" do
      expect(described_class.names).to include(
        :compression_breakout,
        :pullback_continuation,
        :session_breakout,
        :liquidity_sweep_reversal,
        :vwap_reclaim,
        :failed_breakout_reversal
      )
    end
  end

  describe ".matching" do
    it "returns patterns matching compression regime" do
      result = described_class.matching(regime: :compression, bias: :long)
      expect(result).to have_key(:compression_breakout)
    end

    it "returns patterns matching trend_up regime" do
      result = described_class.matching(regime: :trend_up, bias: :long)
      expect(result).to have_key(:pullback_continuation)
    end

    it "returns pullback_continuation for trend_down regardless of bias (both directions valid)" do
      result = described_class.matching(regime: :trend_down, bias: :short)
      expect(result).to have_key(:pullback_continuation)
    end

    it "returns no patterns for chop regime + long bias" do
      result = described_class.matching(regime: :chop, bias: :long)
      expect(result).to be_empty
    end

    it "matches neutral bias to any required_bias pattern" do
      result = described_class.matching(regime: :range, bias: :neutral)
      expect(result).not_to be_empty
    end

    it "returns empty for chop regime" do
      result = described_class.matching(regime: :chop, bias: :long)
      expect(result).to be_empty
    end
  end

  describe ".get" do
    it "returns a specific pattern by name symbol" do
      defn = described_class.get(:compression_breakout)
      expect(defn).to include(:required_regime, :confirmation, :description)
    end

    it "returns nil for unknown pattern" do
      expect(described_class.get(:nonexistent)).to be_nil
    end
  end
end
