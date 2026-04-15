# frozen_string_literal: true

lib_root = __dir__
$LOAD_PATH.unshift(lib_root) unless $LOAD_PATH.include?(lib_root)

require "logger"
require "json"
require "time"
require "fileutils"
require "uri"

# Core dependencies
require "ollama_client"
require "coindcx"

module StrategyBuilder
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class DataError < Error; end
  class ValidationError < Error; end
  class BacktestError < Error; end

  # Market data layer
  autoload :CandleLoader,       "strategy_builder/market_data/candle_loader"
  autoload :InstrumentLoader,   "strategy_builder/market_data/instrument_loader"
  autoload :DataNormalizer,     "strategy_builder/market_data/data_normalizer"
  autoload :CandleStore,        "strategy_builder/market_data/candle_store"

  # Feature engine
  autoload :MtfStack,           "strategy_builder/features/mtf_stack"
  autoload :SessionDetector,    "strategy_builder/features/session_detector"
  autoload :VolatilityProfile,  "strategy_builder/features/volatility_profile"
  autoload :StructureDetector,  "strategy_builder/features/structure_detector"
  autoload :VolumeProfile,      "strategy_builder/features/volume_profile"
  autoload :MomentumEngine,     "strategy_builder/features/momentum_engine"
  autoload :FeatureBuilder,     "strategy_builder/features/feature_builder"

  # Strategy generation
  autoload :PromptBuilder,      "strategy_builder/strategy_builder/prompt_builder"
  autoload :CandidateParser,    "strategy_builder/strategy_builder/candidate_parser"
  autoload :CandidateValidator, "strategy_builder/strategy_builder/candidate_validator"
  autoload :OllamaGeneratePlanner, "strategy_builder/strategy_builder/ollama_generate_planner"
  autoload :LlmInvoker,         "strategy_builder/strategy_builder/llm_invoker"
  autoload :StrategyGenerator,  "strategy_builder/strategy_builder/strategy_generator"
  autoload :StrategyCatalog,    "strategy_builder/strategy_builder/strategy_catalog"
  autoload :StrategyTemplates,  "strategy_builder/strategy_builder/strategy_templates"

  # Backtest
  autoload :BacktestPositionState, "strategy_builder/backtest/position_state"
  autoload :BacktestEngine,     "strategy_builder/backtest/engine"
  autoload :FillModel,          "strategy_builder/backtest/fill_model"
  autoload :SlippageModel,      "strategy_builder/backtest/slippage_model"
  autoload :FeeModel,           "strategy_builder/backtest/fee_model"
  autoload :PartialExitModel,   "strategy_builder/backtest/partial_exit_model"
  autoload :TrailingModel,      "strategy_builder/backtest/trailing_model"
  autoload :Metrics,            "strategy_builder/backtest/metrics"
  autoload :WalkForward,        "strategy_builder/backtest/walk_forward"

  # Ranking
  autoload :Scorer,             "strategy_builder/ranking/scorer"
  autoload :Gatekeeper,         "strategy_builder/ranking/gatekeeper"
  autoload :Robustness,         "strategy_builder/ranking/robustness"

  # Documentation
  autoload :StrategyCard,       "strategy_builder/documentation/strategy_card"
  autoload :MarkdownExporter,   "strategy_builder/documentation/markdown_exporter"
  autoload :JsonExporter,       "strategy_builder/documentation/json_exporter"

  # Agent
  module Agent
    autoload :ParallelInstrumentRunner, "strategy_builder/agent/parallel_instrument_runner"
    autoload :DiscoverPhase, "strategy_builder/agent/discover_phase"
    autoload :ValidatePhase, "strategy_builder/agent/validate_phase"
    autoload :ToolServices, "strategy_builder/agent/tool_services"
  end
  autoload :AgentLoop,          "strategy_builder/agent/agent_loop"
  autoload :ToolRegistry,       "strategy_builder/agent/tool_registry"

  # Signal generation (bridges strategy conditions to backtest signals)
  autoload :SignalGeneratorFactory, "strategy_builder/backtest/signal_generator_factory"

  # Configuration
  autoload :Configuration,      "strategy_builder/configuration"
  autoload :OllamaSslBearerClient, "strategy_builder/ollama/ssl_bearer_client"

  class << self
    def configure
      yield configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def logger
      configuration.logger
    end

    def coindcx_client
      @coindcx_client ||= begin
        CoinDCX.configure do |c|
          c.api_key = configuration.coindcx_api_key
          c.api_secret = configuration.coindcx_api_secret
          c.logger = configuration.logger
          c.max_retries = 2
          c.retry_base_interval = 0.25
        end
        CoinDCX.client
      end
    end

    def ollama_client
      @ollama_client ||= begin
        cfg = configuration
        if cfg.ollama_cloud?
          api_key = cfg.ollama_api_key.to_s.strip
          if api_key.empty?
            raise ConfigurationError,
              "STRATEGY_BUILDER_OLLAMA_CLOUD=1 requires OLLAMA_API_KEY (create a key at https://ollama.com/settings/keys)."
          end

          warn_if_cloud_base_url_mismatch(cfg)
        else
          warn_if_ollama_base_url_is_public_website
          reject_public_ollama_website_base_url!
        end

        config = Ollama::Config.new
        config.base_url = cfg.ollama_base_url if cfg.ollama_base_url
        config.model = cfg.ollama_model
        config.temperature = cfg.ollama_temperature
        config.timeout = cfg.ollama_timeout
        config.num_ctx = cfg.ollama_num_ctx
        config.retries = cfg.ollama_retries

        if cfg.ollama_cloud?
          OllamaSslBearerClient.new(config: config, bearer_token: cfg.ollama_api_key)
        else
          Ollama::Client.new(config: config)
        end
      end
    end

    def reset!
      @configuration = nil
      @coindcx_client = nil
      @ollama_client = nil
      @ollama_public_base_url_warned = false
      @ollama_cloud_base_url_warned = false
    end

    # True when OLLAMA_BASE_URL points at the public ollama.com site (not `ollama serve` HTTP API).
    def public_ollama_website_base_url?(url_string)
      url = url_string.to_s
      return false if url.strip.empty?

      host = URI.parse(url).host&.downcase
      host&.end_with?("ollama.com") == true
    rescue URI::InvalidURIError
      false
    end

    # https://ollama.com is the marketing site / catalog, not the same as `ollama serve` on your machine.
    def warn_if_ollama_base_url_is_public_website
      return if @ollama_public_base_url_warned
      return if configuration.ollama_cloud?

      url = configuration.ollama_base_url.to_s
      return unless public_ollama_website_base_url?(url)

      @ollama_public_base_url_warned = true
      logger.warn do
        "OLLAMA_BASE_URL=#{url} points at the ollama.com website, not a local `ollama serve` instance. " \
          "ollama-client expects the open-source server API (e.g. http://127.0.0.1:11434). " \
          "Unset OLLAMA_BASE_URL or set it to your machine's Ollama listen address; then `ollama pull` your model tag."
      end
    end

    def warn_if_cloud_base_url_mismatch(cfg)
      return if @ollama_cloud_base_url_warned

      url = cfg.ollama_base_url.to_s
      @ollama_cloud_base_url_warned = true
      return if public_ollama_website_base_url?(url)

      logger.info do
        "STRATEGY_BUILDER_OLLAMA_CLOUD=1 with OLLAMA_BASE_URL=#{url} (custom host). " \
          "Official Ollama Cloud API is https://ollama.com; ensure this URL serves /api/generate with your key."
      end
    end

    # Stops the pipeline before LLM calls that would only EOF/reset against the marketing host.
    # Override with OLLAMA_ALLOW_PUBLIC_WEBSITE=1 if you truly intend a custom proxy at that hostname.
    def reject_public_ollama_website_base_url!
      return if configuration.ollama_cloud?

      url = configuration.ollama_base_url.to_s
      return unless public_ollama_website_base_url?(url)
      return if ENV.fetch("OLLAMA_ALLOW_PUBLIC_WEBSITE", "").strip == "1"

      raise ConfigurationError,
        "OLLAMA_BASE_URL=#{url} is not a valid Ollama HTTP API base. Use the URL where `ollama serve` listens " \
        "(e.g. http://127.0.0.1:11434 for native Ollama or Docker publishing 11434 on the same Linux/WSL2 machine). " \
        "Only if the client runs in WSL2 and Ollama runs on the Windows host instead, use the Windows IP from " \
        "`ip route show default | awk '{print $3}'`. To bypass this check (not recommended), set " \
        "OLLAMA_ALLOW_PUBLIC_WEBSITE=1."
    end
  end
end

require "strategy_builder/configuration"
