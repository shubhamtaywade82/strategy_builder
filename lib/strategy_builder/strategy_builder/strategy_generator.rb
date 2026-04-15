# frozen_string_literal: true

module StrategyBuilder
  class StrategyGenerator
    def initialize(client: StrategyBuilder.ollama_client)
      @client = client
      @planner = OllamaGeneratePlanner.build(@client)
      @validator = CandidateValidator.new
      @logger = StrategyBuilder.logger
      @llm_invoker = LlmInvoker.new(planner: @planner, logger: @logger)
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

      candidates = call_llm(prompt, response_schema: PromptBuilder.strategy_candidates_generate_schema)
      if candidates.empty?
        log_ollama_fallback(reason: "Ollama unreachable, stream dropped, invalid JSON, or empty parse")
        candidates = template_fallback_candidates(features: features, count: count)
      end

      validated = @validator.filter_valid(candidates)
      if validated.empty? && candidates.any?
        instrument = features[:instrument] || "unknown"
        @logger.warn do
          "All #{candidates.size} LLM proposals failed validation; seeding from built-in templates " \
            "(instrument: #{instrument})."
        end
        candidates = template_fallback_candidates(
          features: features,
          count: count,
          offline_reason:
            "Seeded from built-in template after LLM proposals failed validation (instrument: #{instrument})."
        )
        validated = @validator.filter_valid(candidates)
      end

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

      candidates = call_llm(prompt, response_schema: PromptBuilder.strategy_candidates_generate_schema)
      if candidates.empty?
        log_ollama_fallback(reason: "mutate call failed same as generate")
        candidates = templates.map { |t| decorate_fallback_template(t, features) }
      end

      validated = @validator.filter_valid(candidates)
      if validated.empty? && candidates.any?
        instrument = features[:instrument] || "unknown"
        @logger.warn do
          "All #{candidates.size} LLM mutations failed validation; using decorated seed template(s) " \
            "(instrument: #{instrument})."
        end
        candidates = templates.map do |t|
          decorate_fallback_template(
            t,
            features,
            offline_reason:
              "Seeded from built-in template after LLM mutations failed validation (instrument: #{instrument})."
          )
        end
        validated = @validator.filter_valid(candidates)
      end

      validated.map { |v| v[:candidate] }
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

    def log_ollama_fallback(reason:)
      cfg = StrategyBuilder.configuration
      @logger.warn { "LLM returned no candidates (#{reason}). Using built-in template fallback." }
      ollama_troubleshooting_lines(cfg).each { |line| @logger.warn { line } }
    end

    def ollama_troubleshooting_lines(cfg)
      if cfg.ollama_bearer_transport?
        return [
          "Ollama Cloud: request failed or returned empty JSON (quota, model name, network, or upstream error).",
          "Config: STRATEGY_BUILDER_OLLAMA_CLOUD=1 | OLLAMA_BASE_URL=#{cfg.ollama_base_url} | " \
            "OLLAMA_AGENT_MODEL/OLLAMA_MODEL=#{cfg.ollama_model} | OLLAMA_TIMEOUT=#{cfg.ollama_timeout}s",
          "Verify OLLAMA_API_KEY is set and not revoked (https://ollama.com/settings/keys).",
          "Smoke test: curl -sS -H \"Authorization: Bearer $OLLAMA_API_KEY\" " \
            "#{cfg.ollama_base_url}/api/tags | head -c 400",
          "Pick a cloud-capable model tag (often ends with -cloud); see model list in Ollama app or docs."
        ]
      end

      [
        "Why EOF / connection reset: the HTTP connection to Ollama closed while reading the response body " \
          "(server crash/OOM, proxy timeout, VPN, Wi-Fi, or WSL2-to-host networking); not a CoinDCX issue.",
        "Config: OLLAMA_BASE_URL=#{cfg.ollama_base_url} | OLLAMA_AGENT_MODEL/OLLAMA_MODEL=#{cfg.ollama_model} | " \
          "OLLAMA_TIMEOUT=#{cfg.ollama_timeout}s | OLLAMA_NUM_CTX=#{cfg.ollama_num_ctx}",
        "Try (this is the host Ruby uses, not ollama.com): curl -sS #{cfg.ollama_base_url}/api/tags | head -c 300",
        "Note: https://ollama.com/api/tags is only a public catalog of names; strategy_builder calls YOUR " \
          "OLLAMA_BASE_URL (usually local ollama serve).",
        "Same machine (native or Docker ollama/ollama on WSL2/Linux): OLLAMA_BASE_URL=http://127.0.0.1:11434. " \
          "WSL2 client + Ollama on Windows host only: Windows IP from `ip route show default | awk '{print $3}'`.",
        "Stability: run `ollama ps`, use a smaller/faster model, lower OLLAMA_NUM_CTX (e.g. 4096), " \
          "raise OLLAMA_TIMEOUT for big thinking models, watch `ollama serve` logs for unload/OOM."
      ]
    end

    # @param response_schema [Hash, nil] Ollama JSON schema; nil uses ollama-client's permissive any-JSON schema.
    def call_llm(prompt, response_schema: nil)
      @llm_invoker.run(prompt, response_schema: response_schema)
    end

    def deep_dup_hash(obj)
      JSON.parse(JSON.generate(obj), symbolize_names: true)
    end

    def decorate_fallback_template(template, features, offline_reason: nil)
      cand = deep_dup_hash(template)
      instrument = features[:instrument] || "unknown"
      cand[:name] = "#{cand[:name]} (offline template)"
      cand[:rationale] = offline_reason ||
        "Seeded from built-in template while the LLM was unavailable (instrument: #{instrument})."
      cand
    end

    def template_fallback_candidates(features:, count: 3, offline_reason: nil)
      n = [count, StrategyTemplates.all.size].min
      StrategyTemplates.all.first(n).map do |template|
        decorate_fallback_template(template, features, offline_reason: offline_reason)
      end
    end

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
