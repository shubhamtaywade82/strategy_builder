# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::MtfStack do
  describe ".sorted_mtf_keys" do
    it "orders coarse timeframes before fine ones regardless of hash key order" do
      keys = ["1m", "5m", "15m"]
      shuffled = keys.shuffle
      expect(described_class.sorted_mtf_keys(shuffled)).to eq(%w[15m 5m 1m])
    end
  end
end
