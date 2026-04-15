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

  describe ".truthy_env?" do
    it "treats 1, true, yes, on as true" do
      %w[1 true yes on].each do |v|
        ENV["SB_TEST_FLAG"] = v
        expect(described_class.truthy_env?("SB_TEST_FLAG")).to be(true), "expected #{v.inspect} to be truthy"
      end
    end

    it "treats unset or other values as false" do
      ENV.delete("SB_TEST_FLAG")
      expect(described_class.truthy_env?("SB_TEST_FLAG")).to be(false)

      ENV["SB_TEST_FLAG"] = "0"
      expect(described_class.truthy_env?("SB_TEST_FLAG")).to be(false)
    end
  end

  describe ".falsey_env?" do
    it "treats 0, false, no, off as true (flag is falsey)" do
      %w[0 false no off].each do |v|
        ENV["SB_TEST_FALSEY"] = v
        expect(described_class.falsey_env?("SB_TEST_FALSEY")).to be(true), "expected #{v.inspect} to be falsey"
      end
    end

    it "treats unset as not falsey" do
      ENV.delete("SB_TEST_FALSEY")
      expect(described_class.falsey_env?("SB_TEST_FALSEY")).to be(false)
    end
  end

  describe "#ollama_bearer_transport?" do
    around do |example|
      saved = %w[STRATEGY_BUILDER_OLLAMA_CLOUD OLLAMA_API_KEY OLLAMA_BASE_URL].to_h { |k| [k, ENV[k]] }
      %w[STRATEGY_BUILDER_OLLAMA_CLOUD OLLAMA_API_KEY OLLAMA_BASE_URL].each { |k| ENV.delete(k) }
      example.run
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end

    it "is true when STRATEGY_BUILDER_OLLAMA_CLOUD=1" do
      ENV["STRATEGY_BUILDER_OLLAMA_CLOUD"] = "1"
      ENV["OLLAMA_API_KEY"] = "k"
      cfg = described_class.new
      cfg.ollama_base_url = "https://ollama.com"
      expect(cfg.ollama_bearer_transport?).to be(true)
    end

    it "is true for https://ollama.com when OLLAMA_API_KEY is set even without cloud flag" do
      ENV["OLLAMA_API_KEY"] = "secret"
      cfg = described_class.new
      cfg.ollama_base_url = "https://ollama.com"
      expect(cfg.ollama_bearer_transport?).to be(true)
    end

    it "is false for https://ollama.com without an API key" do
      ENV.delete("OLLAMA_API_KEY")
      cfg = described_class.new
      cfg.ollama_base_url = "https://ollama.com"
      expect(cfg.ollama_bearer_transport?).to be(false)
    end

    it "is false for local Ollama even with an API key" do
      ENV["OLLAMA_API_KEY"] = "unused"
      cfg = described_class.new
      cfg.ollama_base_url = "http://127.0.0.1:11434"
      expect(cfg.ollama_bearer_transport?).to be(false)
    end
  end

  describe "LLM IO logging" do
    around do |example|
      saved = %w[STRATEGY_BUILDER_LLM_IO_LOG STRATEGY_BUILDER_LLM_IO_LOG_MAX_CHARS].to_h { |k| [k, ENV[k]] }
      %w[STRATEGY_BUILDER_LLM_IO_LOG STRATEGY_BUILDER_LLM_IO_LOG_MAX_CHARS].each { |k| ENV.delete(k) }
      example.run
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end

    it "enables llm_io_log by default" do
      expect(described_class.new.llm_io_log).to be(true)
    end

    it "disables llm_io_log when STRATEGY_BUILDER_LLM_IO_LOG is falsey" do
      ENV["STRATEGY_BUILDER_LLM_IO_LOG"] = "0"
      expect(described_class.new.llm_io_log).to be(false)
    end
  end

  describe ".default_ollama_base_url" do
    around do |example|
      saved = ENV["OLLAMA_BASE_URL"]
      ENV.delete("OLLAMA_BASE_URL")
      example.run
      saved ? ENV["OLLAMA_BASE_URL"] = saved : ENV.delete("OLLAMA_BASE_URL")
    end

    it "uses https://ollama.com for cloud when OLLAMA_BASE_URL is unset" do
      expect(described_class.default_ollama_base_url(true)).to eq("https://ollama.com")
    end

    it "uses OLLAMA_BASE_URL for cloud when set" do
      ENV["OLLAMA_BASE_URL"] = "https://custom.example"
      expect(described_class.default_ollama_base_url(true)).to eq("https://custom.example")
    end

    it "uses local default when not cloud" do
      expect(described_class.default_ollama_base_url(false)).to eq("http://127.0.0.1:11434")
    end
  end

  describe "cloud mode" do
    around do |example|
      saved = %w[STRATEGY_BUILDER_OLLAMA_CLOUD OLLAMA_BASE_URL OLLAMA_API_KEY].to_h { |k| [k, ENV[k]] }
      %w[STRATEGY_BUILDER_OLLAMA_CLOUD OLLAMA_BASE_URL OLLAMA_API_KEY].each { |k| ENV.delete(k) }
      example.run
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end

    it "sets ollama_cloud? from STRATEGY_BUILDER_OLLAMA_CLOUD" do
      ENV["STRATEGY_BUILDER_OLLAMA_CLOUD"] = "1"
      cfg = described_class.new
      expect(cfg.ollama_cloud?).to be(true)
      expect(cfg.ollama_base_url).to eq("https://ollama.com")
    end
  end
end
