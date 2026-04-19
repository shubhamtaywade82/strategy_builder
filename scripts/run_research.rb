#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Full strategy research pipeline — plain Ruby script.
# Usage:
#   bundle exec ruby scripts/run_research.rb
#   bundle exec ruby scripts/run_research.rb pipeline
#   bundle exec ruby scripts/run_research.rb discover
#   bundle exec ruby scripts/run_research.rb data          # data layer only (no LLM)
#   bundle exec ruby scripts/run_research.rb backtest_only # backtest engine only
#
# Env vars (or set in .env):
#   COINDCX_API_KEY, COINDCX_API_SECRET
#   OLLAMA_MODEL, OLLAMA_BASE_URL
#   INSTRUMENTS=B-BTC_USDT,B-ETH_USDT
#   TIMEFRAMES=5m,15m,1h
#   DAYS_BACK=30
#   FRESH=1   (clears catalog before run)

require "bundler/setup"
require "dotenv/load"
require_relative "../lib/strategy_builder"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

INSTRUMENTS = (ENV["INSTRUMENTS"]&.split(",") || ["B-BTC_USDT", "B-ETH_USDT"]).freeze
TIMEFRAMES  = (ENV["TIMEFRAMES"]&.split(",")  || ["5m", "15m", "1h"]).freeze
DAYS_BACK   = (ENV["DAYS_BACK"] || "30").to_i
QUERY       = ARGV[1] || "multi-instrument desk-pipeline research"
MODE        = (ARGV[0] || "pipeline").freeze

StrategyBuilder.configure do |c|
  c.coindcx_api_key    = ENV.fetch("COINDCX_API_KEY", nil)
  c.coindcx_api_secret = ENV.fetch("COINDCX_API_SECRET", nil)
  c.ollama_model       = StrategyBuilder::Configuration.ollama_model_from_env
  c.ollama_base_url    = ENV.fetch("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
  c.default_instruments = INSTRUMENTS
  c.default_timeframes  = TIMEFRAMES
end

def separator(label)
  puts "\n#{"=" * 60}"
  puts "  #{label}"
  puts "=" * 60
end

def print_features(features)
  features.each do |instrument, feat|
    puts "\n  #{instrument}:"
    puts "    regime:      #{feat.dig(:volatility, :regime)}"
    puts "    structure:   #{feat.dig(:structure, :structure)}"
    puts "    mtf_align:   #{feat.dig(:mtf_alignment, :alignment, :regime)}"
    puts "    rsi:         #{feat.dig(:momentum, :rsi_current)&.round(1)}"
    puts "    vol_zscore:  #{feat.dig(:volume, :volume_zscore)&.round(2)}"
    puts "    atr_%:       #{feat.dig(:volatility, :current_atr_percent)&.round(3)}"
    puts "    sessions:    #{Array(feat[:sessions]).join(', ')}"
  end
end

def print_candidates(candidates)
  if candidates.empty?
    puts "  (none)"
    return
  end
  candidates.each do |c|
    puts "  [#{c[:id]}] #{c[:name]} — #{c[:instrument]}"
  end
end

def print_ranked(ranked)
  if ranked.empty?
    puts "  (none)"
    return
  end
  ranked.first(10).each_with_index do |entry, i|
    score  = entry.dig(:ranking, :final_score)&.round(3) || "N/A"
    status = entry[:status]
    name   = entry[:strategy][:name]
    exp    = entry.dig(:backtest_results, :walk_forward, :aggregate, :oos_expectancy)&.round(3) || "N/A"
    puts "  #{i + 1}. #{name}"
    puts "       score=#{score}  status=#{status}  oos_expectancy=#{exp}"
  end
end

def print_catalog_summary(catalog)
  puts "\n  Total:     #{catalog.size}"
  puts "  Passing:   #{catalog.passing.size}"
  puts "  Watchlist: #{catalog.by_status('watchlist').size}"
  puts "  Rejected:  #{catalog.by_status('reject').size}"
  puts "  Proposed:  #{catalog.by_status('proposed').size}"
end

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

case MODE

# --------------------------------------------------------------------------
when "pipeline", "full"
  separator("PIPELINE: #{QUERY}")
  puts "  instruments: #{INSTRUMENTS.join(', ')}"
  puts "  timeframes:  #{TIMEFRAMES.join(', ')}"
  puts "  days_back:   #{DAYS_BACK}"

  if ENV["FRESH"] == "1"
    StrategyBuilder::StrategyCatalog.new.clear!
    puts "\n  Catalog cleared (FRESH=1)."
  end

  agent = StrategyBuilder::AgentLoop.new

  separator("Phase 1: Discover")
  features = agent.discover(
    instruments: INSTRUMENTS,
    timeframes:  TIMEFRAMES,
    days_back:   DAYS_BACK
  )
  print_features(features)

  separator("Phase 2: Propose (DeskPipeline)")
  puts "  Observer → PatternAnalyst → TradeDesigner → Skeptic (per instrument)"
  candidates = agent.propose(features_by_instrument: features)
  puts "\n  Candidates added to catalog:"
  print_candidates(candidates)

  separator("Phase 3: Validate (Walk-Forward Backtest)")
  agent.validate(
    instruments: INSTRUMENTS,
    days_back:   [DAYS_BACK * 3, 365].min
  )
  puts "  Backtest complete."

  separator("Phase 4: Rank")
  ranked = agent.rank
  print_ranked(ranked)

  separator("Phase 5: Document")
  agent.document
  puts "  Strategy cards exported."

  catalog = StrategyBuilder::StrategyCatalog.new
  summary_path = catalog.write_pipeline_run_summary(query: QUERY)
  separator("Pipeline Complete")
  print_catalog_summary(catalog)
  puts "\n  Run summary: #{summary_path}"

# --------------------------------------------------------------------------
when "discover"
  separator("DISCOVER ONLY")
  agent    = StrategyBuilder::AgentLoop.new
  features = agent.discover(
    instruments: INSTRUMENTS,
    timeframes:  TIMEFRAMES,
    days_back:   DAYS_BACK
  )
  print_features(features)

# --------------------------------------------------------------------------
when "propose"
  separator("PROPOSE ONLY")
  agent    = StrategyBuilder::AgentLoop.new
  features = agent.discover(
    instruments: INSTRUMENTS,
    timeframes:  TIMEFRAMES,
    days_back:   DAYS_BACK
  )
  candidates = agent.propose(features_by_instrument: features)
  print_candidates(candidates)

# --------------------------------------------------------------------------
when "data"
  # Data layer only — no LLM, no backtest. Inspect raw features.
  separator("DATA LAYER ONLY (no LLM)")

  loader = StrategyBuilder::CandleLoader.new

  INSTRUMENTS.each do |instrument|
    separator("#{instrument} — features")

    mtf = loader.fetch_mtf(
      instrument: instrument,
      timeframes: TIMEFRAMES,
      from: Time.now - (DAYS_BACK * 86_400)
    )

    puts "  Candle counts: #{mtf.transform_values(&:size)}"

    features = StrategyBuilder::FeatureBuilder.build(
      instrument: instrument,
      mtf_candles: mtf
    )

    puts "\n  === Volatility ==="
    puts "    regime:      #{features.dig(:volatility, :regime)}"
    puts "    current_atr: #{features.dig(:volatility, :current_atr)&.round(4)}"
    puts "    atr_%:       #{features.dig(:volatility, :current_atr_percent)&.round(3)}"

    puts "\n  === Structure ==="
    puts "    classification: #{features.dig(:structure, :structure)}"
    puts "    swing_highs:    #{features.dig(:structure, :swing_highs)&.last(3)&.map { |s| s[:price].round(2) }}"
    puts "    swing_lows:     #{features.dig(:structure, :swing_lows)&.last(3)&.map { |s| s[:price].round(2) }}"

    puts "\n  === MTF Alignment ==="
    align = features.dig(:mtf_alignment, :alignment)
    puts "    regime:          #{align&.dig(:regime)}"
    puts "    score:           #{align&.dig(:alignment)&.round(3)}"
    puts "    aligned_bullish: #{align&.dig(:aligned_bullish)}"
    puts "    aligned_bearish: #{align&.dig(:aligned_bearish)}"

    puts "\n  === Market State (SnapshotBuilder) ==="
    state = StrategyBuilder::State::SnapshotBuilder.build(
      instrument: instrument,
      features: features
    )
    puts "    regime:         #{state.regime}"
    puts "    session:        #{state.session}"
    puts "    bias:           #{state.bias}"
    puts "    higher_tf_bias: #{state.higher_tf_bias}"
    puts "    volatility:     #{state.volatility}"
    puts "    volume:         #{state.volume}"

    puts "\n  === Pattern Candidates ==="
    patterns = StrategyBuilder::Patterns::PatternMiner.mine(state)
    if patterns.empty?
      puts "    (none above MIN_SCORE)"
    else
      patterns.each do |p|
        puts "    #{p[:name]}  score=#{p[:score]}  entry=#{p[:entry_type]}"
        puts "      evidence: #{p[:evidence].join(' | ')}"
      end
    end

    puts "\n  === Liquidity Map ==="
    liq = state.liquidity
    puts "    equal_highs:     #{liq[:equal_highs]&.first(3)}"
    puts "    equal_lows:      #{liq[:equal_lows]&.first(3)}"
    puts "    nearest_support: #{liq[:nearest_support]&.round(4)}"
    puts "    nearest_resist:  #{liq[:nearest_resist]&.round(4)}"
  end

# --------------------------------------------------------------------------
when "backtest_only"
  # Backtest engine standalone — uses first passing strategy in catalog.
  separator("BACKTEST ENGINE ONLY")

  catalog = StrategyBuilder::StrategyCatalog.new
  entry   = catalog.passing.first || catalog.all.first

  if entry.nil?
    puts "No strategies in catalog. Run 'pipeline' or 'propose' first."
    exit 1
  end

  strategy = entry[:strategy]
  puts "  Strategy: #{strategy[:name]}"

  loader = StrategyBuilder::CandleLoader.new
  mtf    = loader.fetch_mtf(
    instrument: INSTRUMENTS.first,
    timeframes: TIMEFRAMES,
    from: Time.now - (DAYS_BACK * 86_400)
  )
  candles = mtf[TIMEFRAMES.first] || mtf.values.first

  signal_gen = StrategyBuilder::SignalEvaluator.build(strategy, mtf_candles: mtf)
  engine     = StrategyBuilder::BacktestEngine.new
  result     = engine.run(strategy: strategy, candles: candles, signal_generator: signal_gen, mtf_candles: mtf)

  m = result[:metrics]
  separator("Backtest Results")
  puts "  trade_count:    #{m[:trade_count]}"
  puts "  win_rate:       #{m[:win_rate]&.round(3)}"
  puts "  expectancy:     #{m[:expectancy]&.round(4)}"
  puts "  profit_factor:  #{m[:profit_factor]&.round(3)}"
  puts "  max_drawdown:   #{m[:max_drawdown]&.round(4)}"
  puts "  net_pnl:        #{m[:net_pnl]&.round(4)}"

  result[:trades].last(5).each_with_index do |t, i|
    puts "  trade #{i + 1}: dir=#{t[:direction]} pnl_r=#{t[:pnl_r]&.round(3)} reason=#{t[:exit_reason]}"
  end

# --------------------------------------------------------------------------
else
  puts "Unknown mode: #{MODE}"
  puts "Usage: bundle exec ruby scripts/run_research.rb [pipeline|discover|propose|data|backtest_only] [query]"
  exit 1
end
