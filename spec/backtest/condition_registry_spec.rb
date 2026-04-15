# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::ConditionRegistry do
  describe ".condition_ids" do
    it "returns sorted registered condition names" do
      ids = described_class.condition_ids
      expect(ids).to eq(ids.sort)
      expect(ids).to include("asia_range_defined", "session_high_break", "volume_confirmation")
      expect(ids).not_to be_empty
    end
  end
end
