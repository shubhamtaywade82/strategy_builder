# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::CandidateParser do
  describe ".parse" do
    let(:one) { { "name" => "Test", "family" => "custom" } }

    it "parses a JSON array after leading prose" do
      raw = %(Thoughts first...\n[{"name":"Edge","family":"custom","timeframes":["15m"],"entry":{"conditions":["c1"]},"exit":{"targets":[1.5]},"risk":{"stop":"below swing","position_sizing":"fixed_risk_percent"}}])
      out = described_class.parse(raw)
      expect(out.size).to eq(1)
      expect(out.first[:name]).to eq("Edge")
    end

    it "drops non-hash elements from a JSON array" do
      raw = JSON.generate(["_", one.merge("timeframes" => ["15m"], "entry" => { "conditions" => ["x"] },
        "exit" => { "targets" => [1.0] }, "risk" => { "stop" => "s", "position_sizing" => "fixed_risk_percent" })])
      out = described_class.parse(raw)
      expect(out.size).to eq(1)
      expect(out.first[:name]).to eq("Test")
    end
  end

  describe ".extract_balanced_json_fragment" do
    it "returns nil when there is no JSON start" do
      expect(described_class.extract_balanced_json_fragment("not json")).to be_nil
    end
  end
end
