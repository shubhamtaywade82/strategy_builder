# Strategy Builder

A research-and-ranking pipeline for discovering, validating, and documenting cryptocurrency futures trading strategies using Ollama thinking models and CoinDCX market data.

**This is a research tool, not an autonomous trader.** The LLM proposes hypotheses within schema-locked constraints. The deterministic engine decides pass/fail.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      Agent Loop                          │
│  (orchestrates pipeline, manages tool calls)             │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │ Market Data  │  │ Feature      │  │ Strategy       │  │
│  │ Layer        │  │ Engine       │  │ Generator      │  │
│  │              │  │              │  │                │  │
│  │ CoinDCX API  │→│ MTF Stack    │→│ Ollama Planner │  │
│  │ Candles      │  │ Volatility   │  │ Schema-locked  │  │
│  │ Instruments  │  │ Structure    │  │ JSON output    │  │
│  │ Stats        │  │ Volume       │  │ Validation     │  │
│  └─────────────┘  │ Momentum     │  └────────────────┘  │
│                    │ Sessions     │          │            │
│                    └──────────────┘          ▼            │
│                                   ┌────────────────────┐ │
│                                   │ Walk-Forward       │ │
│                                   │ Backtester         │ │
│                                   │                    │ │
│                                   │ Fill + Slippage    │ │
│                                   │ Partial exits      │ │
│                                   │ Trailing stops     │ │
│                                   │ Fee model          │ │
│                                   └────────────────────┘ │
│                                            │             │
│                                            ▼             │
│                    ┌────────────────────────────────────┐ │
│                    │ Ranking Engine                     │ │
│                    │ Composite scorer + Hard gates      │ │
│                    │ Robustness testing                 │ │
│                    └────────────────────────────────────┘ │
│                                            │             │
│                                            ▼             │
│                    ┌────────────────────────────────────┐ │
│                    │ Documentation                      │ │
│                    │ Strategy cards (MD + JSON)         │ │
│                    │ LLM-enhanced explanations          │ │
│                    └────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

## Dependencies

The project integrates three Ruby gems:

**ollama-client** provides the LLM execution layer: schema-constrained generation via `Planner` (stateless, `/api/generate`), tool-calling via `Executor` (stateful, `/api/chat`), thinking mode support, and structured JSON output with validation. The LLM never executes side effects; it only proposes.

**coindcx-client** provides the market data layer: REST endpoints for futures candles, active instruments, stats, and instrument metadata, plus WebSocket channels for live orderbook and trades. The gem handles rate limiting, retries, and structured error classification.

**ollama_agent** is referenced for its `ToolRuntime` pattern: a small tool surface with read/search/edit separation, a sandboxed review loop, and explicit agent modes (analysis, interactive, automated). The agent loop in this project borrows that orchestration pattern without copying the CLI shape.

## Setup

```bash
cp .env.example .env
# Edit .env with your CoinDCX API credentials

bundle install

# Ensure Ollama is running with a thinking-capable model
ollama pull qwen3:8b
```

## Usage

### Full Pipeline

```bash
ruby exe/strategy_builder pipeline "Find breakout strategies for BTC and ETH"
```

### Step-by-Step

```bash
# Discover market features
ruby exe/strategy_builder discover --instruments B-BTC_USDT B-ETH_USDT --days 30

# Propose strategy candidates
ruby exe/strategy_builder propose --mode generate

# Backtest proposed strategies
ruby exe/strategy_builder backtest --days 90

# Rank and gate
ruby exe/strategy_builder rank

# Export documentation
ruby exe/strategy_builder document

# View catalog
ruby exe/strategy_builder catalog --status pass
```

### Agent Mode

```bash
ruby exe/strategy_builder research "Analyze compression patterns on SOL, find expansion breakout strategies"
```

### Ruby API

```ruby
require "strategy_builder"

StrategyBuilder.configure do |c|
  c.coindcx_api_key = ENV["COINDCX_API_KEY"]
  c.coindcx_api_secret = ENV["COINDCX_API_SECRET"]
  c.ollama_model = "qwen3:8b"
  c.default_instruments = %w[B-BTC_USDT B-ETH_USDT]
  c.default_timeframes = %w[5m 15m 1h]
end

agent = StrategyBuilder::AgentLoop.new

# Discover features
features = agent.discover(days_back: 30)

# Propose strategies
candidates = agent.propose(features_by_instrument: features)

# Validate
agent.validate(days_back: 90)

# Rank
ranked = agent.rank

# Document
agent.document
```

## Strategy Candidate Schema

Every strategy candidate must conform to a strict JSON schema with these required fields:

- **name**: Human-readable strategy name
- **family**: One of: `session_breakout`, `session_mean_reversion`, `mtf_pullback`, `compression_breakout`, `failed_breakout`, `vwap_reclaim`, `volume_continuation`, `atr_expansion`, `structure_shift`, `custom`
- **timeframes**: Array of timeframes used (e.g., `["15m", "5m", "1m"]`)
- **entry**: Conditions array, direction
- **exit**: R-multiple targets, partial exit fractions, trail config, time stop
- **risk**: Stop logic, position sizing method, max risk percent (hard cap: 3.0%)

Optional but recommended: `session`, `filters`, `invalidation`, `parameter_ranges`, `rationale`.

## Ranking Formula

Strategies are scored on a composite formula:

```
score = 0.25 * expectancy
      + 0.20 * profit_factor
      + 0.15 * oos_stability
      + 0.15 * drawdown_resilience
      + 0.10 * session_consistency
      + 0.10 * parameter_robustness
      + 0.05 * trade_frequency
```

Hard gates reject strategies that fail any of these checks: too few trades (<20), negative OOS expectancy, profit factor below 1.1, excessive IS-to-OOS degradation (>70%), win rate below 25%, or unstable across folds.

## Built-in Strategy Templates

Six seed families are included for the LLM to mutate:

1. **Asia Range Breakout** — session_breakout family
2. **Session Range Mean Reversion** — session_mean_reversion family
3. **MTF Trend Pullback Entry** — mtf_pullback family
4. **Compression Expansion Breakout** — compression_breakout family
5. **Failed Breakout Reversal** — failed_breakout family
6. **VWAP Reclaim Continuation** — vwap_reclaim family

## Testing

```bash
bundle exec rspec
```

## Module Map

```
lib/strategy_builder/
  market_data/
    candle_loader.rb          # CoinDCX OHLCV fetcher
    instrument_loader.rb      # Active futures instruments
    data_normalizer.rb        # Internal shape normalization
  features/
    mtf_stack.rb              # Multi-timeframe alignment
    session_detector.rb       # Session tagging (Asia/London/NY)
    volatility_profile.rb     # ATR, compression, expansion
    structure_detector.rb     # Swing points, MSS, breakouts
    volume_profile.rb         # Relative volume, VWAP, bursts
    momentum_engine.rb        # RSI, MACD, EMA, ROC
    feature_builder.rb        # Orchestrates all features
  strategy_builder/
    strategy_templates.rb     # 6 hardcoded seed strategies
    prompt_builder.rb         # LLM prompts (generate/mutate/critique/document)
    candidate_parser.rb       # JSON parse with fence stripping
    candidate_validator.rb    # Schema + structural validation
    strategy_generator.rb     # Ollama Planner integration
    strategy_catalog.rb       # JSON-file persistence
  backtest/
    engine.rb                 # Event-driven backtester
    fill_model.rb             # Fill, slippage, fee, partial, trailing models
    metrics.rb                # Comprehensive performance metrics
    walk_forward.rb           # Walk-forward OOS validation
  ranking/
    scorer.rb                 # Composite scoring
    gatekeeper.rb             # Hard rejection gates (renamed from scorer.rb)
    robustness.rb             # Parameter sensitivity analysis (in scorer.rb)
  documentation/
    strategy_card.rb          # Card builder, MD exporter, JSON exporter
  agent/
    agent_loop.rb             # Pipeline orchestrator
    tool_registry.rb          # Agent tools (ToolRuntime pattern)
    schemas/
      strategy_candidate.json # JSON Schema for validation
```

## License

MIT
