# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::OllamaGeneratePlanner do
  let(:client) { instance_double(Ollama::Client) }

  describe "#run" do
    it "merges system prompt, JSON context, and calls generate with strict schema" do
      planner = described_class.new(client)
      allow(client).to receive(:generate).and_return([])

      planner.run(
        prompt: "emit json",
        context: { system: "You are a test" },
        schema: nil
      )

      expect(client).to have_received(:generate) do |kwargs|
        expect(kwargs[:strict]).to eq(true)
        expect(kwargs[:schema]).to eq(described_class::ANY_JSON_SCHEMA)
        expect(kwargs[:prompt]).to include("emit json")
        expect(kwargs[:prompt]).to include("Context (JSON):")
        expect(kwargs[:prompt]).to include("You are a test")
      end
    end
  end

  describe ".build" do
    it "returns the official planner when Ollama::Agent::Planner is defined" do
      skip "ollama-client without Agent::Planner" unless defined?(Ollama::Agent::Planner)

      built = described_class.build(client)
      expect(built).to be_a(Ollama::Agent::Planner)
    end
  end
end
