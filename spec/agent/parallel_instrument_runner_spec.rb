# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Agent::ParallelInstrumentRunner do
  describe ".map_parallel" do
    it "falls back to sequential map when max_parallel is 1" do
      out = described_class.map_parallel([1, 2, 3], max_parallel: 1) { |x| x * 2 }
      expect(out).to eq([2, 4, 6])
    end

    it "returns parallel results for independent work" do
      out = described_class.map_parallel([1, 2, 3], max_parallel: 3) { |x| x + 10 }
      expect(out.sort).to eq([11, 12, 13])
    end
  end
end
