# frozen_string_literal: true

require "uri"

module StrategyBuilder
  class Configuration
    VALID_TIMEFRAMES = %w[1m 3m 5m 15m 30m 1h 2h 4h 6h 1d 1w].freeze

    # First non-empty wins: OLLAMA_AGENT_MODEL (preferred), then OLLAMA_MODEL, then default.
    # The name must exist on your Ollama server (`ollama list`); unknown tags return HTTP 404.
    DEFAULT_OLLAMA_MODEL = "qwen3.5:4b"

    def self.ollama_model_from_env
      %w[OLLAMA_AGENT_MODEL OLLAMA_MODEL].each do |key|
        val = ENV[key]&.strip
        return val if val && !val.empty?
      end
      DEFAULT_OLLAMA_MODEL
    end

    def self.truthy_env?(name)
      val = ENV[name]&.strip&.downcase
      %w[1 true yes on].include?(val)
    end

    def self.falsey_env?(name)
      val = ENV[name]&.strip&.downcase
      %w[0 false no off].include?(val)
    end

    def self.default_ollama_base_url(cloud)
      if cloud
        raw = ENV["OLLAMA_BASE_URL"]&.strip
        return raw if raw && !raw.empty?

        "https://ollama.com"
      else
        ENV.fetch("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
      end
    end

    attr_accessor :coindcx_api_key, :coindcx_api_secret,
                  :ollama_model, :ollama_temperature, :ollama_timeout,
                  :ollama_base_url, :ollama_num_ctx, :ollama_retries,
                  :ollama_llm_max_attempts, :ollama_llm_retry_base_seconds,
                  :ollama_api_key,
                  :llm_io_log, :llm_io_log_max_chars,
                  :default_instruments, :default_timeframes,
                  :backtest_fee_rate, :backtest_slippage_bps,
                  :backtest_spread_bps, :backtest_slippage_volatility_scale,
                  :walk_forward_in_sample_ratio,
                  :max_strategy_candidates, :max_agent_iterations,
                  :output_dir, :logger,
                  :parallel_instrument_max,
                  :backtest_indicator_warmup,
                  :backtest_default_stop_price_fraction

    # Ollama Cloud (https://ollama.com/api) when STRATEGY_BUILDER_OLLAMA_CLOUD is truthy; requires OLLAMA_API_KEY.
    def ollama_cloud?
      @ollama_cloud == true
    end

    # True when OLLAMA_BASE_URL host is ollama.com (marketing/API host), not a local ollama serve.
    def ollama_public_website_host?
      url = @ollama_base_url.to_s
      return false if url.strip.empty?

      host = URI.parse(url).host&.downcase
      host&.end_with?("ollama.com") == true
    rescue URI::InvalidURIError
      false
    end

    # Use TLS + Bearer (OllamaSslBearerClient): explicit cloud flag or ollama.com URL with an API key.
    def ollama_bearer_transport?
      return true if ollama_cloud?

      ollama_public_website_host? && !@ollama_api_key.to_s.strip.empty?
    end

    def initialize
      @coindcx_api_key = ENV.fetch("COINDCX_API_KEY", nil)
      @coindcx_api_secret = ENV.fetch("COINDCX_API_SECRET", nil)

      @ollama_model = self.class.ollama_model_from_env
      @ollama_temperature = 0.3
      # Large prompts + thinking models often need >120s on CPU-bound hosts.
      @ollama_timeout = Integer(ENV.fetch("OLLAMA_TIMEOUT", "240"))
      @ollama_cloud = self.class.truthy_env?("STRATEGY_BUILDER_OLLAMA_CLOUD")
      @ollama_api_key = ENV["OLLAMA_API_KEY"]&.strip
      # Cloud: default API root is https://ollama.com (see https://docs.ollama.com/api). Local: ollama serve.
      @ollama_base_url = self.class.default_ollama_base_url(@ollama_cloud)
      @ollama_num_ctx = Integer(ENV.fetch("OLLAMA_NUM_CTX", "8192"))
      @ollama_retries = Integer(ENV.fetch("OLLAMA_CLIENT_RETRIES", "2"))
      @ollama_llm_max_attempts = Integer(ENV.fetch("STRATEGY_BUILDER_OLLAMA_LLM_ATTEMPTS", "5"))
      @ollama_llm_retry_base_seconds = Float(ENV.fetch("STRATEGY_BUILDER_OLLAMA_RETRY_BASE", "0.75"))
      # Log prompts and raw model output (truncated). Disable with STRATEGY_BUILDER_LLM_IO_LOG=0.
      @llm_io_log = !self.class.falsey_env?("STRATEGY_BUILDER_LLM_IO_LOG")
      @llm_io_log_max_chars = Integer(ENV.fetch("STRATEGY_BUILDER_LLM_IO_LOG_MAX_CHARS", "16000"))

      @default_instruments = %w[B-BTC_USDT B-ETH_USDT B-SOL_USDT]
      @default_timeframes = %w[1m 5m 15m 1h 4h]

      @backtest_fee_rate = 0.0005       # 5 bps maker
      @backtest_slippage_bps = 2.0      # 2 bps simulated slippage
      @backtest_spread_bps = Float(ENV.fetch("STRATEGY_BUILDER_SPREAD_BPS", "1.0"))
      @backtest_slippage_volatility_scale = self.class.truthy_env?("STRATEGY_BUILDER_VOL_SLIPPAGE")
      @walk_forward_in_sample_ratio = 0.7

      @max_strategy_candidates = 50
      @max_agent_iterations = 20

      # AgentLoop: max concurrent CoinDCX fetches (bounded to avoid rate-limit / thundering herd).
      @parallel_instrument_max = Integer(ENV.fetch("STRATEGY_BUILDER_PARALLEL_INSTRUMENTS", "6"))
      # BacktestEngine / SignalEvaluator: candles required before signals (indicator warmup).
      @backtest_indicator_warmup = Integer(ENV.fetch("STRATEGY_BUILDER_BACKTEST_WARMUP", "50"))
      # When strategy/signal does not specify stop distance, use this fraction of last close.
      @backtest_default_stop_price_fraction = Float(ENV.fetch("STRATEGY_BUILDER_DEFAULT_STOP_FRAC", "0.01"))

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
