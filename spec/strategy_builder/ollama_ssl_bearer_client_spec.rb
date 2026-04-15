# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::OllamaSslBearerClient do
  let(:ollama_config) do
    Ollama::Config.new.tap do |c|
      c.base_url = "https://ollama.com"
      c.model = "test:cloud"
      c.timeout = 30
      c.temperature = 0.2
      c.top_p = 0.9
      c.num_ctx = 4096
      c.retries = 0
    end
  end

  let(:client) { described_class.new(config: ollama_config, bearer_token: "secret-token") }

  describe "#generate" do
    it "posts to /api/generate over HTTPS with Authorization" do
      stub_request(:post, "https://ollama.com/api/generate")
        .with(
          headers: { "Authorization" => "Bearer secret-token", "Content-Type" => "application/json" }
        )
        .to_return(
          status: 200,
          body: { model: "test:cloud", response: "[{\"name\":\"X\",\"family\":\"custom\"}]", done: true }.to_json
        )

      out = client.generate(
        prompt: "hi",
        schema: { "type" => "array" },
        strict: true
      )

      expect(out).to eq([{ "name" => "X", "family" => "custom" }])
    end
  end
end
