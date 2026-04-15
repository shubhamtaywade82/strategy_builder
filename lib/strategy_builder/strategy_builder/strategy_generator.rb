# frozen_string_literal: true

module StrategyBuilder
  class StrategyGenerator
    def initialize(client: StrategyBuilder.ollama_client)
      @client = client
      @planner = OllamaGeneratePlanner.build(@client)
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
      if candidates.empty?
        @logger.warn do
          "LLM returned no candidates (Ollama down, timeout, or empty parse). " \
            "Using built-in template fallback — check OLLAMA_BASE_URL, OLLAMA_TIMEOUT, and `ollama list`."
        end
        candidates = template_fallback_candidates(features: features, count: count)
      end

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
      if candidates.empty?
        @logger.warn { "LLM returned no candidates for mutate; using template fallback." }
        candidates = templates.map { |t| decorate_fallback_template(t, features) }
      end

      @validator.filter_valid(candidates).map { |v| v[:candidate] }
    end

    # Critique existing strategies against features.
    # Returns critique objects, not strategy candidates.
    def critique(features:, strategies:)
      prompt = PromptBuilder.critique_prompt(
        features: compact_features(features),
        templates: strategies
      )

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

    def transient_network_error?(error)
      error.is_a?(EOFError) ||
        error.is_a?(OpenSSL::SSL::SSLError) ||
        error.is_a?(SocketError) ||
        error.is_a?(Net::OpenTimeout) ||
        error.is_a?(Net::ReadTimeout) ||
        (error.is_a?(Errno::ECONNRESET) || error.is_a?(Errno::EPIPE) ||
         error.is_a?(Errno::ECONNREFUSED) || error.is_a?(Errno::EHOSTUNREACH))
    end

    def ollama_error_retryable?(error)
      return false if error.is_a?(Ollama::NotFoundError)

      return true if error.is_a?(Ollama::RetryExhaustedError)
      return true if error.is_a?(Ollama::TimeoutError)
      return error.retryable? if error.is_a?(Ollama::HTTPError)

      msg = error.message.to_s.downcase
      %w[connection reset refused eof timeout broken pipe].any? { |fragment| msg.include?(fragment) }
    end

    def llm_retry_sleep(attempt)
      base = StrategyBuilder.configuration.ollama_llm_retry_base_seconds
      sleep([base * (2**(attempt - 1)), 16.0].min)
    end

    # Call LLM with retry logic and backoff for flaky local Ollama / truncated streams.
    def call_llm(prompt)
      max_attempts = [StrategyBuilder.configuration.ollama_llm_max_attempts, 1].max
      attempts = 0

      loop do
        attempts += 1
        begin
          raw = @planner.run(
            prompt: prompt,
            context: { system: PromptBuilder::SYSTEM_PROMPT }
          )

          if raw.is_a?(Hash) || raw.is_a?(Array)
            return raw.is_a?(Array) ? raw : [raw]
          end

          parsed = CandidateParser.parse(raw.to_s)
          return parsed if parsed.any?

          raise "Empty parse result"
        rescue Ollama::NotFoundError => e
          model = StrategyBuilder.configuration.ollama_model
          hint = if e.respond_to?(:suggestions) && e.suggestions&.any?
                     " Ollama suggests: #{e.suggestions.first(3).join(', ')}."
                   else
                     ""
                   end
          msg = "No Ollama model #{model.inspect} on this server.#{hint} " \
                "Set OLLAMA_AGENT_MODEL (or OLLAMA_MODEL) in .env to a tag from `ollama list`, " \
                "run `ollama pull <tag>`, and retry."
          raise ConfigurationError, msg, cause: e
        rescue Ollama::SchemaViolationError, Ollama::InvalidJSONError => e
          @logger.warn { "LLM output invalid (attempt #{attempts}/#{max_attempts}): #{e.message}" }
          return [] if attempts >= max_attempts

          llm_retry_sleep(attempts)
        rescue Ollama::TimeoutError => e
          @logger.warn { "LLM timeout (attempt #{attempts}/#{max_attempts}): #{e.message}" }
          return [] if attempts >= max_attempts

          llm_retry_sleep(attempts)
        rescue Ollama::Error => e
          if ollama_error_retryable?(e)
            @logger.warn { "LLM transport error (attempt #{attempts}/#{max_attempts}): #{e.message}" }
            return [] if attempts >= max_attempts

            llm_retry_sleep(attempts)
            next
          end

          @logger.error { "LLM error: #{e.message}" }
          raise
        rescue StandardError => e
          if transient_network_error?(e) || e.message == "Empty parse result"
            @logger.warn { "LLM call failed (attempt #{attempts}/#{max_attempts}): #{e.message}" }
            return [] if attempts >= max_attempts

            llm_retry_sleep(attempts)
            next
          end

          raise
        end
      end
    end

    def deep_dup_hash(obj)
      JSON.parse(JSON.generate(obj), symbolize_names: true)
    end

    def decorate_fallback_template(template, features)
      cand = deep_dup_hash(template)
      instrument = features[:instrument] || "unknown"
      cand[:name] = "#{cand[:name]} (offline template)"
      cand[:rationale] =
        "Seeded from built-in template while the LLM was unavailable (instrument: #{instrument})."
      cand
    end

    def template_fallback_candidates(features:, count: 3)
      n = [count, StrategyTemplates.all.size].min
      StrategyTemplates.all.first(n).map { |template| decorate_fallback_template(template, features) }
    end

    # Strip large arrays from features to fit context window.
    def compact_features(features)
      compacted = features.dup
      compacted.delete(:candles)
      compacted.delete(:raw_candles)

      if compacted[:per_timeframe_summary]
        compacted[:per_timeframe_summary] = compacted[:per_timeframe_summary].transform_values do |v|
          v.is_a?(Hash) ? v.reject { |k, _| k == :candles } : v
        end
      end

      if compacted[:session_ranges]
        compacted[:session_ranges] = compacted[:session_ranges].transform_values do |v|
          v.is_a?(Hash) ? v.slice(:session, :date, :high, :low, :open, :close) : v
        end
      end

      compacted
    end
  end
end
