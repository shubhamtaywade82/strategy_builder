# frozen_string_literal: true

module StrategyBuilder
  # Wraps ollama-client's Ollama::Agent::Planner when present (0.2.x). For ollama-client 1.x,
  # that namespace was removed; this class mirrors Planner#run using Ollama::Client#generate.
  class OllamaGeneratePlanner
    ANY_JSON_SCHEMA = {
      "anyOf" => [
        { "type" => "object", "additionalProperties" => true },
        { "type" => "array" },
        { "type" => "string" },
        { "type" => "number" },
        { "type" => "integer" },
        { "type" => "boolean" },
        { "type" => "null" }
      ]
    }.freeze

    def self.build(client)
      return Ollama::Agent::Planner.new(client) if defined?(Ollama::Agent::Planner)

      new(client)
    end

    def initialize(client)
      @client = client
    end

    # Same contract as Ollama::Agent::Planner#run (ollama-client 0.2.x).
    def run(prompt:, context: nil, schema: nil, system_prompt: nil)
      effective_system = system_prompt
      full_prompt = prompt.to_s
      if effective_system && !effective_system.to_s.strip.empty?
        full_prompt = "#{effective_system}\n\n#{full_prompt}"
      end

      if context && !context.empty?
        full_prompt = "#{full_prompt}\n\nContext (JSON):\n#{JSON.pretty_generate(context)}"
      end

      @client.generate(
        prompt: full_prompt,
        schema: schema.nil? ? ANY_JSON_SCHEMA : schema,
        strict: true
      )
    end
  end
end
