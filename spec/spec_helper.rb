# frozen_string_literal: true

require "bundler/setup"
require "strategy_builder"
require "webmock/rspec"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random

  config.before(:each) do
    StrategyBuilder.reset!
    StrategyBuilder.configure do |c|
      c.coindcx_api_key = "test_key"
      c.coindcx_api_secret = "test_secret"
      c.ollama_model = "test-model"
      c.ollama_base_url = "http://127.0.0.1:11434"
      c.logger = Logger.new(File::NULL)
      c.output_dir = Dir.mktmpdir
    end
  end
end

# Shared test data factories
module TestData
  def self.candle(timestamp: Time.now.to_i, open: 100.0, high: 105.0, low: 95.0, close: 102.0, volume: 1000.0, timeframe: "5m")
    { timestamp: timestamp, open: open, high: high, low: low, close: close, volume: volume, timeframe: timeframe }
  end

  def self.candle_series(count: 200, base_price: 100.0, timeframe: "5m")
    price = base_price
    start_ts = Time.now.to_i - (count * 300) # 5m intervals

    count.times.map do |i|
      change = (rand - 0.48) * 2.0 # slight upward bias
      price += change
      price = [price, 1.0].max # floor at 1.0

      high = price + rand * 1.5
      low = price - rand * 1.5

      candle(
        timestamp: start_ts + (i * 300),
        open: price - change,
        high: high,
        low: [low, 0.5].max,
        close: price,
        volume: 500 + rand(2000),
        timeframe: timeframe
      )
    end
  end

  def self.mtf_candles(instruments: ["B-BTC_USDT"], timeframes: %w[5m 15m 1h])
    timeframes.each_with_object({}) do |tf, result|
      count = case tf
              when "1m" then 500
              when "5m" then 200
              when "15m" then 100
              when "1h" then 50
              when "4h" then 30
              else 100
              end
      result[tf] = candle_series(count: count, timeframe: tf)
    end
  end

  def self.strategy_candidate
    {
      name: "Test Breakout Strategy",
      family: "session_breakout",
      timeframes: %w[15m 5m],
      session: %w[london],
      entry: {
        conditions: %w[session_high_break volume_confirmation],
        direction: "long"
      },
      exit: {
        targets: [1.0, 2.0],
        partial_exits: [0.5, 0.5],
        trail: "atr_1_5_after_1R"
      },
      risk: {
        stop: "below_session_low",
        position_sizing: "fixed_risk_percent",
        max_risk_percent: 1.0
      },
      filters: {
        min_volume_zscore: 1.5,
        min_atr_percent: 0.4
      },
      invalidation: %w[failed_breakout session_end],
      parameter_ranges: {
        atr_multiplier_stop: [0.5, 2.0]
      },
      rationale: "Test strategy for unit tests"
    }
  end
end
