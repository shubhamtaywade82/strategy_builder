# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::AgentLoop do
  describe ".register_phase / .phase_registry / #run_phase" do
    after do
      described_class.instance_variable_set(:@phase_registry, nil)
    end

    it "allows registering a custom phase without editing the default case list" do
      agent = described_class.new
      described_class.register_phase(:ping) { |_a, **kw| { ok: true, **kw } }

      expect(agent.run_phase(:ping, foo: 1)).to eq(ok: true, foo: 1)
    end

    it "still runs built-in discover via registry" do
      discover = instance_double(StrategyBuilder::Agent::DiscoverPhase)
      allow(discover).to receive(:execute).and_return({})

      agent = described_class.new(discover_phase: discover)
      agent.run_phase(:discover, instruments: ["B-BTC_USDT"], timeframes: ["5m"], days_back: 1)

      expect(discover).to have_received(:execute).with(
        hash_including(
          instruments: ["B-BTC_USDT"],
          timeframes: ["5m"],
          days_back: 1,
          memory: agent.memory
        )
      )
    end
  end
end
