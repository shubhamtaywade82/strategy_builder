# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::Configuration do
  describe ".ollama_model_from_env" do
    around do |example|
      saved = %w[OLLAMA_AGENT_MODEL OLLAMA_MODEL].to_h { |k| [k, ENV[k]] }
      %w[OLLAMA_AGENT_MODEL OLLAMA_MODEL].each { |k| ENV.delete(k) }
      example.run
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end

    it "prefers OLLAMA_AGENT_MODEL over OLLAMA_MODEL" do
      ENV["OLLAMA_MODEL"] = "from-model"
      ENV["OLLAMA_AGENT_MODEL"] = "from-agent"

      expect(described_class.ollama_model_from_env).to eq("from-agent")
    end

    it "falls back to OLLAMA_MODEL when OLLAMA_AGENT_MODEL is unset" do
      ENV["OLLAMA_MODEL"] = "fallback"

      expect(described_class.ollama_model_from_env).to eq("fallback")
    end

    it "uses DEFAULT_OLLAMA_MODEL when both are unset" do
      expect(described_class.ollama_model_from_env).to eq(described_class::DEFAULT_OLLAMA_MODEL)
    end

    it "ignores blank strings" do
      ENV["OLLAMA_AGENT_MODEL"] = "  "
      ENV["OLLAMA_MODEL"] = "valid"

      expect(described_class.ollama_model_from_env).to eq("valid")
    end
  end
end
