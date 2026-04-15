# frozen_string_literal: true

module StrategyBuilder
  class Configuration
    VALID_TIMEFRAMES = %w[1m 3m 5m 15m 30m 1h 2h 4h 6h 1d 1w].freeze

    attr_accessor :coindcx_api_key, :coindcx_api_secret,
                  :ollama_model, :ollama_temperature, :ollama_timeout,
                  :ollama_base_url,
                  :default_instruments, :default_timeframes,
                  :backtest_fee_rate, :backtest_slippage_bps,
                  :walk_forward_in_sample_ratio,
                  :max_strategy_candidates, :max_agent_iterations,
                  :output_dir, :logger

    def initialize
      @coindcx_api_key = ENV.fetch("COINDCX_API_KEY", nil)
      @coindcx_api_secret = ENV.fetch("COINDCX_API_SECRET", nil)

      @ollama_model = ENV.fetch("OLLAMA_AGENT_MODEL", "qwen3:8b")
      @ollama_temperature = 0.3
      @ollama_timeout = 120
      @ollama_base_url = ENV.fetch("OLLAMA_BASE_URL", "http://localhost:11434")

      @default_instruments = %w[B-BTC_USDT B-ETH_USDT B-SOL_USDT]
      @default_timeframes = %w[1m 5m 15m 1h 4h]

      @backtest_fee_rate = 0.0005       # 5 bps maker
      @backtest_slippage_bps = 2.0      # 2 bps simulated slippage
      @walk_forward_in_sample_ratio = 0.7

      @max_strategy_candidates = 50
      @max_agent_iterations = 20

      @output_dir = File.expand_path("output", __dir__)
      @logger = Logger.new($stdout, level: Logger::INFO)
    end

    def validate!
      raise ConfigurationError, "COINDCX_API_KEY required" unless @coindcx_api_key
      raise ConfigurationError, "COINDCX_API_SECRET required" unless @coindcx_api_secret

      invalid_tf = @default_timeframes - VALID_TIMEFRAMES
      raise ConfigurationError, "Invalid timeframes: #{invalid_tf}" if invalid_tf.any?

      true
    end
  end
end
