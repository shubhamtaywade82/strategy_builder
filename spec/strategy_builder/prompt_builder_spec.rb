# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::PromptBuilder do
  describe ".strategy_candidates_generate_schema" do
    it "constrains entry.conditions items to ConditionRegistry.condition_ids" do
      schema = described_class.strategy_candidates_generate_schema
      enum = schema.dig("items", "properties", "entry", "properties", "conditions", "items", "enum")
      expect(enum).to eq(StrategyBuilder::ConditionRegistry.condition_ids)
      expect(enum).to include("asia_range_defined")
    end
  end

  describe ".system_prompt" do
    it "includes a known registry slug for the LLM contract" do
      expect(described_class.system_prompt).to include("asia_range_defined")
    end
  end

  describe ".new_strategy_prompt" do
    let(:features) { { instrument: "B-TEST_USDT", volatility: { regime: :normal } } }
    let(:templates) { StrategyBuilder::StrategyTemplates.all }

    it "embeds allowed condition ids in the task prompt" do
      body = described_class.new_strategy_prompt(features: features, templates: templates)
      expect(body).to include("ALLOWED_ENTRY_CONDITION_IDS")
      expect(body).to include("asia_range_defined")
    end
  end
end
