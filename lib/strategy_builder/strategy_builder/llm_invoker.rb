# frozen_string_literal: true

module StrategyBuilder
  # Wraps Ollama planner calls with retries, backoff, and response normalization (keeps StrategyGenerator thin).
  class LlmInvoker
    def initialize(planner:, logger: StrategyBuilder.logger)
      @planner = planner
      @logger = logger
    end

    # @param response_schema [Hash, nil] Ollama JSON schema; nil uses permissive any-JSON schema.
    def run(prompt, response_schema: nil)
      max_attempts = [StrategyBuilder.configuration.ollama_llm_max_attempts, 1].max
      attempts = 0
      schema_for_llm = response_schema || OllamaGeneratePlanner::ANY_JSON_SCHEMA

      loop do
        attempts += 1
        begin
          raw = @planner.run(
            prompt: prompt,
            context: {},
            system_prompt: PromptBuilder::SYSTEM_PROMPT,
            schema: schema_for_llm
          )

          if raw.is_a?(Hash) || raw.is_a?(Array)
            return normalize_llm_candidate_list(raw)
          end

          parsed = CandidateParser.parse(raw.to_s)
          return parsed if parsed.any?

          raise "Empty parse result"
        rescue Ollama::NotFoundError => e
          raise ConfigurationError, not_found_message(e), cause: e
        rescue Ollama::SchemaViolationError, Ollama::InvalidJSONError => e
          warn_retry("LLM output invalid", e, attempts, max_attempts)
          return [] if attempts >= max_attempts

          llm_retry_sleep(attempts)
        rescue Ollama::TimeoutError => e
          warn_retry("LLM timeout", e, attempts, max_attempts)
          return [] if attempts >= max_attempts

          llm_retry_sleep(attempts)
        rescue Ollama::Error => e
          if ollama_error_retryable?(e)
            warn_retry("LLM transport error", e, attempts, max_attempts)
            return [] if attempts >= max_attempts

            llm_retry_sleep(attempts)
            next
          end

          @logger.error { "LLM error: #{e.message}" }
          raise
        rescue StandardError => e
          if transient_network_error?(e) || e.message == "Empty parse result"
            warn_retry("LLM call failed", e, attempts, max_attempts)
            return [] if attempts >= max_attempts

            llm_retry_sleep(attempts)
            next
          end

          raise
        end
      end
    end

    private

    def warn_retry(label, error, attempts, max_attempts)
      @logger.warn { "#{label} (attempt #{attempts}/#{max_attempts}): #{error.message}" }
    end

    def not_found_message(error)
      model = StrategyBuilder.configuration.ollama_model
      hint = if error.respond_to?(:suggestions) && error.suggestions&.any?
                 " Ollama suggests: #{error.suggestions.first(3).join(', ')}."
               else
                 ""
               end
      "No Ollama model #{model.inspect} on this server.#{hint} " \
        "Set OLLAMA_AGENT_MODEL (or OLLAMA_MODEL) in .env to a tag from `ollama list`, " \
        "run `ollama pull <tag>`, and retry."
    end

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

    def normalize_llm_candidate_list(raw)
      list = raw.is_a?(Array) ? raw : [raw]
      list.filter_map do |item|
        next unless item.is_a?(Hash)

        CandidateParser.symbolize_keys_deep(item)
      end
    end
  end
end
