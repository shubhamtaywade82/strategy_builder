# frozen_string_literal: true

module StrategyBuilder
  class StrategyGenerator
    MAX_RETRIES = 3

    def initialize(client: StrategyBuilder.ollama_client)
      @client = client
      @planner = Ollama::Agent::Planner.new(@client)
      @validator = CandidateValidator.new
      @logger = StrategyBuilder.logger
    end

    # Generate new strategy candidates from feature data.
    # Uses schema-locked generation via ollama-client Planner.
    def generate(features:, count: 3)
      templates = StrategyTemplates.all
      prompt = PromptBuilder.generation_prompt(
        features: compact_features(features),
        templates: templates,
        mode: :generate
      )

      candidates = call_llm(prompt)
      validated = @validator.filter_valid(candidates)

      @logger.info { "Generated #{candidates.size} candidates, #{validated.size} passed validation" }
      validated.map { |v| v[:candidate] }
    end

    # Mutate existing templates using current market features.
    def mutate(features:, template: nil)
      templates = template ? [template] : [StrategyTemplates.all.sample]
      prompt = PromptBuilder.generation_prompt(
        features: compact_features(features),
        templates: templates,
        mode: :mutate
      )

      candidates = call_llm(prompt)
      @validator.filter_valid(candidates).map { |v| v[:candidate] }
    end

    # Critique existing strategies against features.
    # Returns critique objects, not strategy candidates.
    def critique(features:, strategies:)
      prompt = PromptBuilder.critique_prompt(
        features: compact_features(features),
        templates: strategies
      )

      # Critique uses a different schema, so no candidate validation.
      call_llm(prompt)
    end

    # Generate documentation for a strategy.
    def document(strategy:, backtest_results:)
      prompt = PromptBuilder.documentation_prompt(
        strategy: strategy,
        backtest_results: backtest_results
      )

      result = call_llm(prompt)
      result.is_a?(Array) ? result.first : result
    end

    private

    # Call LLM with retry logic.
    # Uses Planner (stateless, /api/generate) with schema enforcement.
    def call_llm(prompt)
      retries = 0

      loop do
        begin
          raw = @planner.run(
            prompt: prompt,
            context: { system: PromptBuilder::SYSTEM_PROMPT }
          )

          # Planner returns parsed JSON if it can, or a string.
          if raw.is_a?(Hash) || raw.is_a?(Array)
            return raw.is_a?(Array) ? raw : [raw]
          end

          # Fallback: parse string response
          parsed = CandidateParser.parse(raw.to_s)
          return parsed if parsed.any?

          raise "Empty parse result"
        rescue Ollama::SchemaViolationError, Ollama::InvalidJSONError => e
          retries += 1
          @logger.warn { "LLM output invalid (attempt #{retries}/#{MAX_RETRIES}): #{e.message}" }
          raise if retries >= MAX_RETRIES
        rescue Ollama::TimeoutError => e
          retries += 1
          @logger.warn { "LLM timeout (attempt #{retries}/#{MAX_RETRIES}): #{e.message}" }
          raise if retries >= MAX_RETRIES
        rescue Ollama::Error => e
          @logger.error { "LLM error: #{e.message}" }
          raise
        rescue StandardError => e
          retries += 1
          @logger.warn { "Parse failure (attempt #{retries}/#{MAX_RETRIES}): #{e.message}" }
          return [] if retries >= MAX_RETRIES
        end
      end
    end

    # Strip large arrays from features to fit context window.
    # The LLM sees summaries, not raw candle arrays.
    def compact_features(features)
      compacted = features.dup
      compacted.delete(:candles)
      compacted.delete(:raw_candles)

      # Remove per-TF details that are too large
      if compacted[:per_timeframe_summary]
        compacted[:per_timeframe_summary] = compacted[:per_timeframe_summary].transform_values do |v|
          v.is_a?(Hash) ? v.reject { |k, _| k == :candles } : v
        end
      end

      # Remove large session range arrays
      if compacted[:session_ranges]
        compacted[:session_ranges] = compacted[:session_ranges].transform_values do |v|
          v.is_a?(Hash) ? v.slice(:session, :date, :high, :low, :open, :close) : v
        end
      end

      compacted
    end
  end
end
