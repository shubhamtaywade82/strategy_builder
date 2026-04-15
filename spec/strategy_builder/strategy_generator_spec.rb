# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StrategyBuilder::StrategyGenerator do
  before do
    StrategyBuilder.configure do |c|
      c.ollama_llm_max_attempts = 2
      c.ollama_llm_retry_base_seconds = 0.01
    end
  end

  let(:features) do
    {
      instrument: 'B-BTC_USDT',
      mtf_alignment: { alignment: { regime: :bullish } },
      volatility: { regime: :normal, current_atr_percent: 0.8 },
      structure: { structure: :bullish },
      momentum: { rsi_current: 55 },
      volume: { relative_volume_current: 1.2 }
    }
  end

  describe '#generate' do
    it 'returns validated built-in templates when the LLM returns nothing' do
      planner = instance_double(Ollama::Agent::Planner)
      allow(StrategyBuilder::OllamaGeneratePlanner).to receive(:build).and_return(planner)
      allow(planner).to receive(:run).and_return('')

      generator = described_class.new(client: StrategyBuilder.ollama_client)
      out = generator.generate(features: features, count: 2)

      expect(out.size).to eq(2)
      expect(out.first[:name]).to include('offline template')
      expect(out.first[:rationale]).to include('LLM was unavailable')
    end
  end

  describe '#mutate' do
    it 'falls back to the seed template when the LLM returns nothing' do
      planner = instance_double(Ollama::Agent::Planner)
      allow(StrategyBuilder::OllamaGeneratePlanner).to receive(:build).and_return(planner)
      allow(planner).to receive(:run).and_return('')

      generator = described_class.new(client: StrategyBuilder.ollama_client)
      out = generator.mutate(features: features)

      expect(out.size).to eq(1)
      expect(out.first[:name]).to include('offline template')
    end
  end
end
