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
  autoload :StrategyGenerator,  "strategy_builder/strategy_builder/strategy_generator"
  autoload :StrategyCatalog,    "strategy_builder/strategy_builder/strategy_catalog"
  autoload :StrategyTemplates,  "strategy_builder/strategy_builder/strategy_templates"

  # Backtest
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
  autoload :AgentLoop,          "strategy_builder/agent/agent_loop"
  autoload :ToolRegistry,       "strategy_builder/agent/tool_registry"

  # Signal generation (bridges strategy conditions to backtest signals)
  autoload :SignalGeneratorFactory, "strategy_builder/backtest/signal_generator_factory"

  # Configuration
  autoload :Configuration,      "strategy_builder/configuration"

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
        warn_if_ollama_base_url_is_public_website
        config = Ollama::Config.new
        config.base_url = configuration.ollama_base_url if configuration.ollama_base_url
        config.model = configuration.ollama_model
        config.temperature = configuration.ollama_temperature
        config.timeout = configuration.ollama_timeout
        config.num_ctx = configuration.ollama_num_ctx
        config.retries = configuration.ollama_retries
        Ollama::Client.new(config: config)
      end
    end

    def reset!
      @configuration = nil
      @coindcx_client = nil
      @ollama_client = nil
      @ollama_public_base_url_warned = false
    end

    # https://ollama.com is the marketing site / catalog, not the same as `ollama serve` on your machine.
    def warn_if_ollama_base_url_is_public_website
      return if @ollama_public_base_url_warned

      url = configuration.ollama_base_url.to_s
      host = URI.parse(url).host&.downcase
      return unless host&.end_with?("ollama.com")

      @ollama_public_base_url_warned = true
      logger.warn do
        "OLLAMA_BASE_URL=#{url} points at the ollama.com website, not a local `ollama serve` instance. " \
          "ollama-client expects the open-source server API (e.g. http://127.0.0.1:11434). " \
          "Unset OLLAMA_BASE_URL or set it to your machine's Ollama listen address; then `ollama pull` your model tag."
      end
    end
  end
end

require "strategy_builder/configuration"
