# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::LlmInvoker do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }
  let(:planner) { instance_double(Ollama::Agent::Planner) }

  before do
    StrategyBuilder.configure do |c|
      c.logger = logger
      c.llm_io_log = true
      c.llm_io_log_max_chars = 800
      c.ollama_llm_max_attempts = 1
      c.ollama_llm_retry_base_seconds = 0.01
    end
  end

  it "logs system prompt, user prompt, context, schema note, and raw response" do
    allow(planner).to receive(:run).and_return({ "name" => "Alpha" })

    described_class.new(planner: planner, logger: logger).run(
      "find edges on SOL",
      response_schema: { "type" => "object" }
    )

    combined = log_io.string
    expect(combined).to include("LLM IO — system_prompt")
    expect(combined).to include("LLM IO — user_prompt")
    expect(combined).to include("find edges on SOL")
    expect(combined).to include("LLM IO — context")
    expect(combined).to include("LLM IO — schema=custom")
    expect(combined).to include("LLM IO — response (Hash")
    expect(combined).to include("Alpha")
  end

  it "skips LLM IO lines when llm_io_log is false" do
    StrategyBuilder.configure { |c| c.llm_io_log = false }
    allow(planner).to receive(:run).and_return({ "k" => "v" })

    described_class.new(planner: planner, logger: logger).run("x")

    expect(log_io.string).not_to include("LLM IO —")
  end
end
