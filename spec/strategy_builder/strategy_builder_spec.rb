# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::StrategyTemplates do
  describe ".all" do
    it "returns 6 seed templates" do
      expect(described_class.all.size).to eq(6)
    end

    it "each template has required keys" do
      described_class.all.each do |t|
        expect(t).to include(:name, :family, :timeframes, :entry, :exit, :risk)
      end
    end

    it "each template has valid exit partial sums" do
      described_class.all.each do |t|
        next unless t.dig(:exit, :partial_exits)

        sum = t[:exit][:partial_exits].sum
        expect(sum).to be_within(0.05).of(1.0),
          "Template #{t[:name]} partial exits sum to #{sum}"
      end
    end
  end

  describe ".families" do
    it "returns unique family names" do
      families = described_class.families
      expect(families).to include("session_breakout", "mtf_pullback", "compression_breakout")
      expect(families.size).to eq(families.uniq.size)
    end
  end
end

RSpec.describe StrategyBuilder::CandidateParser do
  describe ".parse" do
    it "parses a valid JSON array" do
      raw = '[{"name": "Test", "family": "custom"}]'
      result = described_class.parse(raw)
      expect(result.size).to eq(1)
      expect(result.first[:name]).to eq("Test")
    end

    it "strips markdown fences" do
      raw = "```json\n{\"name\": \"Test\"}\n```"
      result = described_class.parse(raw)
      expect(result.size).to eq(1)
    end

    it "handles single objects (wraps in array)" do
      raw = '{"name": "Solo"}'
      result = described_class.parse(raw)
      expect(result.size).to eq(1)
    end

    it "returns empty array on invalid JSON" do
      result = described_class.parse("not json at all")
      expect(result).to eq([])
    end
  end
end

RSpec.describe StrategyBuilder::PromptBuilder do
  let(:features) do
    {
      instrument: "B-BTC_USDT",
      mtf_alignment: { alignment: { regime: :bullish } },
      volatility: { regime: :normal, current_atr_percent: 0.8 },
      structure: { structure: :bullish },
      momentum: { rsi_current: 55 },
      volume: { relative_volume_current: 1.2 }
    }
  end

  let(:templates) { StrategyBuilder::StrategyTemplates.all }

  describe ".generation_prompt" do
    it "returns a non-empty prompt string" do
      prompt = described_class.generation_prompt(features: features, templates: templates, mode: :generate)
      expect(prompt).to be_a(String)
      expect(prompt.length).to be > 100
    end

    it "includes the instrument in the prompt" do
      prompt = described_class.generation_prompt(features: features, templates: templates, mode: :generate)
      expect(prompt).to include("B-BTC_USDT")
    end
  end

  describe ".mutation_prompt" do
    it "includes a template to mutate" do
      prompt = described_class.new_strategy_prompt(features: features, templates: templates)
      expect(prompt).to include("EXISTING TEMPLATE FAMILIES")
    end
  end

  describe ".documentation_prompt" do
    it "includes strategy and backtest data" do
      strategy = TestData.strategy_candidate
      backtest = { metrics: StrategyBuilder::Metrics.empty_metrics }
      prompt = described_class.documentation_prompt(strategy: strategy, backtest_results: backtest)
      expect(prompt).to include(strategy[:name])
    end
  end
end

RSpec.describe StrategyBuilder::StrategyCard do
  describe ".build" do
    it "produces a card with all sections" do
      entry = {
        id: "test_strat_123",
        strategy: TestData.strategy_candidate,
        status: "pass",
        created_at: Time.now.utc.iso8601,
        updated_at: Time.now.utc.iso8601,
        backtest_results: { metrics: StrategyBuilder::Metrics.empty_metrics },
        ranking: { final_score: 0.65, component_scores: {} },
        documentation: nil
      }

      card = described_class.build(entry)
      expect(card).to include(:name, :family, :summary, :entry_checklist, :exit_plan, :risk_model, :invalidation)
      expect(card[:name]).to eq("Test Breakout Strategy")
    end
  end
end

RSpec.describe StrategyBuilder::MarkdownExporter do
  describe ".render" do
    it "produces a markdown string with headers" do
      card = {
        id: "test_123",
        name: "Test Strategy",
        family: "session_breakout",
        status: "pass",
        summary: "A test strategy",
        edge_explanation: "Edge from testing",
        best_conditions: { timeframes: %w[5m], sessions: %w[london], regimes: %w[normal] },
        entry_checklist: %w[condition_a condition_b],
        exit_plan: { targets_r: [1.0, 2.0], partial_exits: [0.5, 0.5], trail: "atr", time_stop: nil },
        risk_model: { stop: "below_low", sizing: "fixed_risk_percent", max_risk: 1.0 },
        ranking_score: 0.72,
        component_scores: {},
        invalidation: %w[failure_a],
        failure_modes: %w[mode_a mode_b],
        parameter_bounds: { atr_mult: [0.5, 2.0] },
        performance: StrategyBuilder::Metrics.empty_metrics,
        updated_at: Time.now.utc.iso8601
      }

      md = described_class.render(card)
      expect(md).to include("# Strategy Card: Test Strategy")
      expect(md).to include("## Entry Checklist")
      expect(md).to include("condition_a")
    end
  end
end

RSpec.describe StrategyBuilder do
  describe ".warn_if_ollama_base_url_is_public_website" do
    around do |example|
      StrategyBuilder.reset!
      example.run
      StrategyBuilder.reset!
    end

    it "logs once when OLLAMA_BASE_URL points at ollama.com" do
      StrategyBuilder.configure { |c| c.ollama_base_url = "https://ollama.com" }
      expect(StrategyBuilder.logger).to receive(:warn).once
      StrategyBuilder.warn_if_ollama_base_url_is_public_website
      StrategyBuilder.warn_if_ollama_base_url_is_public_website
    end

    it "does not log for a local Ollama listen address" do
      StrategyBuilder.configure { |c| c.ollama_base_url = "http://127.0.0.1:11434" }
      expect(StrategyBuilder.logger).not_to receive(:warn)
      StrategyBuilder.warn_if_ollama_base_url_is_public_website
    end
  end

  describe ".ollama_client" do
    around do |example|
      saved = ENV.fetch("OLLAMA_ALLOW_PUBLIC_WEBSITE", nil)
      ENV.delete("OLLAMA_ALLOW_PUBLIC_WEBSITE")
      StrategyBuilder.reset!
      example.run
      StrategyBuilder.reset!
      saved ? ENV["OLLAMA_ALLOW_PUBLIC_WEBSITE"] = saved : ENV.delete("OLLAMA_ALLOW_PUBLIC_WEBSITE")
    end

    it "raises ConfigurationError when OLLAMA_BASE_URL is the public ollama.com site" do
      StrategyBuilder.configure do |c|
        c.ollama_base_url = "https://ollama.com"
        c.coindcx_api_key = "k"
        c.coindcx_api_secret = "s"
      end

      expect { StrategyBuilder.ollama_client }.to raise_error(StrategyBuilder::ConfigurationError, /OLLAMA_BASE_URL/)
    end

    it "raises when OLLAMA_ALLOW_PUBLIC_WEBSITE=1 but ollama.com has no OLLAMA_API_KEY (Bearer required)" do
      ENV["OLLAMA_ALLOW_PUBLIC_WEBSITE"] = "1"
      ENV.delete("OLLAMA_API_KEY")
      StrategyBuilder.reset!
      StrategyBuilder.configure do |c|
        c.ollama_base_url = "https://ollama.com"
        c.ollama_api_key = ""
        c.coindcx_api_key = "k"
        c.coindcx_api_secret = "s"
      end

      expect { StrategyBuilder.ollama_client }.to raise_error(StrategyBuilder::ConfigurationError, /OLLAMA_API_KEY/)
    end

    it "uses OllamaSslBearerClient when ollama.com and OLLAMA_API_KEY are set without STRATEGY_BUILDER_OLLAMA_CLOUD" do
      ENV.delete("STRATEGY_BUILDER_OLLAMA_CLOUD")
      ENV["OLLAMA_API_KEY"] = "implicit-cloud-key"
      StrategyBuilder.reset!
      StrategyBuilder.configure do |c|
        c.ollama_base_url = "https://ollama.com"
        c.ollama_api_key = "implicit-cloud-key"
        c.coindcx_api_key = "k"
        c.coindcx_api_secret = "s"
      end

      client = StrategyBuilder.ollama_client
      expect(client).to be_a(StrategyBuilder::OllamaSslBearerClient)
    ensure
      ENV.delete("OLLAMA_API_KEY")
      StrategyBuilder.reset!
    end

    it "uses OllamaSslBearerClient when STRATEGY_BUILDER_OLLAMA_CLOUD=1 and OLLAMA_API_KEY is set" do
      ENV["STRATEGY_BUILDER_OLLAMA_CLOUD"] = "1"
      ENV["OLLAMA_API_KEY"] = "cloud-key"
      ENV.delete("OLLAMA_BASE_URL")
      StrategyBuilder.reset!
      StrategyBuilder.configure do |c|
        c.ollama_base_url = "https://ollama.com"
        c.ollama_api_key = "cloud-key"
        c.coindcx_api_key = "k"
        c.coindcx_api_secret = "s"
      end

      client = StrategyBuilder.ollama_client
      expect(client).to be_a(StrategyBuilder::OllamaSslBearerClient)
    ensure
      ENV.delete("STRATEGY_BUILDER_OLLAMA_CLOUD")
      ENV.delete("OLLAMA_API_KEY")
      StrategyBuilder.reset!
    end

    it "raises ConfigurationError when cloud mode is on but API key is missing" do
      ENV["STRATEGY_BUILDER_OLLAMA_CLOUD"] = "1"
      ENV.delete("OLLAMA_API_KEY")
      StrategyBuilder.reset!
      StrategyBuilder.configure do |c|
        c.ollama_base_url = "https://ollama.com"
        c.ollama_api_key = ""
        c.coindcx_api_key = "k"
        c.coindcx_api_secret = "s"
      end

      expect { StrategyBuilder.ollama_client }.to raise_error(StrategyBuilder::ConfigurationError, /OLLAMA_API_KEY/)
    ensure
      ENV.delete("STRATEGY_BUILDER_OLLAMA_CLOUD")
      StrategyBuilder.reset!
    end
  end
end
