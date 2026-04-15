# frozen_string_literal: true

lib_root = __dir__
$LOAD_PATH.unshift(lib_root) unless $LOAD_PATH.include?(lib_root)

require "logger"
require "json"
require "time"
require "fileutils"

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
        config = Ollama::Config.new
        config.model = configuration.ollama_model
        config.temperature = configuration.ollama_temperature
        config.timeout = configuration.ollama_timeout
        Ollama::Client.new(config: config)
      end
    end

    def reset!
      @configuration = nil
      @coindcx_client = nil
      @ollama_client = nil
    end
  end
end

require "strategy_builder/configuration"
