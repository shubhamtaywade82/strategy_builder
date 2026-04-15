# frozen_string_literal: true

module StrategyBuilder
  class AgentLoop
    # The orchestration layer. Borrows from ollama_agent's ToolRuntime:
    # - Planner proposes (stateless, /api/generate)
    # - Executor runs tools (stateful, /api/chat)
    # - Memory holds step results
    # - Loop terminates on "done" or max_steps

    AGENT_SYSTEM_PROMPT = <<~SYSTEM
      You are a quantitative strategy research agent for CoinDCX cryptocurrency futures.

      Your mission: discover, validate, and document trading strategies with measurable edge.

      WORKFLOW:
      1. DISCOVER: Fetch market data, compute features, identify patterns across instruments and timeframes.
      2. PROPOSE: Generate strategy candidates using templates and market observations.
      3. VALIDATE: Backtest every candidate with walk-forward analysis. No strategy passes without OOS validation.
      4. RANK: Score strategies on composite metrics. Apply hard gates. Reject weak candidates.
      5. DOCUMENT: Export strategy cards for passing strategies.

      TOOLS AVAILABLE:
      - list_instruments: Find tradeable futures pairs
      - fetch_candles / fetch_mtf_candles: Get OHLCV data
      - compute_features: Run feature engine on candle data
      - list_templates: See available strategy templates
      - generate_strategies: Use LLM to propose new candidates
      - list_catalog: View strategy catalog
      - backtest_strategy: Run walk-forward backtest
      - rank_strategies: Score and rank backtested strategies
      - export_strategy_card: Generate documentation

      RULES:
      - Always fetch real data before proposing strategies.
      - Never skip backtesting.
      - If a strategy fails validation, log why and move on.
      - Prefer mutation of proven templates over novel invention.
      - Document everything — a strategy without documentation is not a strategy.
    SYSTEM

    def initialize(
      client: StrategyBuilder.ollama_client,
      registry: ToolRegistry.new,
      max_steps: nil
    )
      @client = client
      @registry = registry
      @max_steps = max_steps || StrategyBuilder.configuration.max_agent_iterations
      @logger = StrategyBuilder.logger
      @memory = []
      @step_count = 0
    end

    # Run the full research pipeline.
    # query: what the agent should investigate (e.g., "Find breakout strategies for BTC on 5m/15m")
    # Returns: { steps: [...], final_result: ..., strategies_found: Int }
    def run(query:)
      @logger.info { "Agent starting: #{query}" }
      result, steps = run_with_executor(executor: build_executor, query: query)
      catalog = StrategyCatalog.new
      {
        steps: steps,
        final_result: result,
        strategies_found: catalog.size,
        passing_strategies: catalog.passing.size
      }
    end

    # Run a specific phase of the pipeline (for granular control).
    def run_phase(phase, **kwargs)
      case phase
      when :discover
        discover(**kwargs)
      when :propose
        propose(**kwargs)
      when :validate
        validate(**kwargs)
      when :rank
        rank(**kwargs)
      when :document
        document(**kwargs)
      else
        raise ArgumentError, "Unknown phase: #{phase}"
      end
    end

    # --- Individual pipeline phases (for manual/step-by-step execution) ---

    def discover(instruments: nil, timeframes: nil, days_back: 30)
      instruments ||= StrategyBuilder.configuration.default_instruments
      timeframes ||= StrategyBuilder.configuration.default_timeframes

      results = {}
      loader = CandleLoader.new

      instruments.each do |instrument|
        @logger.info { "Discovering features for #{instrument}..." }
        from = Time.now - (days_back * 86_400)
        mtf = loader.fetch_mtf(instrument: instrument, timeframes: timeframes, from: from)
        features = FeatureBuilder.build(instrument: instrument, mtf_candles: mtf)
        results[instrument] = features
        @memory << { phase: :discover, instrument: instrument, features: features }
      end

      results
    end

    def propose(features_by_instrument:, mode: :generate)
      generator = StrategyGenerator.new
      catalog = StrategyCatalog.new
      all_candidates = []
      seen_proposal_keys = {}

      features_by_instrument.each do |instrument, features|
        @logger.info { "Proposing strategies for #{instrument} (mode: #{mode})..." }

        candidates = if mode == :mutate
                       generator.mutate(features: features)
                     else
                       generator.generate(features: features)
                     end

        candidates.each do |candidate|
          key = proposal_dedupe_key(candidate)
          if seen_proposal_keys[key]
            @logger.info { "Skipping duplicate proposal #{candidate[:name]} (#{key})" }
            next
          end

          seen_proposal_keys[key] = true
          id = catalog.add(candidate)
          all_candidates << { id: id, name: candidate[:name], instrument: instrument }
          @logger.info { "Added candidate: #{candidate[:name]} (#{id})" }
        end
      end

      @memory << { phase: :propose, candidates: all_candidates }
      all_candidates
    end

    def validate(catalog: StrategyCatalog.new, instruments: nil, days_back: 90)
      instruments ||= StrategyBuilder.configuration.default_instruments
      engine = BacktestEngine.new
      walk_forward = WalkForward.new(engine: engine)

      proposed = catalog.by_status("proposed")
      @logger.info { "Validating #{proposed.size} proposed strategies..." }

      proposed.each do |entry|
        strategy = entry[:strategy]

        instruments.each do |instrument|
          @logger.info { "Backtesting #{strategy[:name]} on #{instrument}..." }

          # Build signal generator from the strategy's entry conditions.
          signal_gen = SignalGeneratorFactory.build(strategy)

          loader = CandleLoader.new
          from = Time.now - (days_back * 86_400)
          primary_tf = strategy[:timeframes]&.last || "5m"
          candles = loader.fetch(instrument: instrument, timeframe: primary_tf, from: from)

          next if candles.size < 200

          wf_result = walk_forward.run(
            strategy: strategy,
            candles: candles,
            signal_generator: signal_gen
          )

          catalog.attach_backtest(entry[:id], {
            metrics: wf_result[:aggregate],
            walk_forward: wf_result,
            instrument: instrument,
            candle_count: candles.size
          })

          @memory << { phase: :validate, strategy_id: entry[:id], instrument: instrument, result: wf_result[:aggregate] }
        end
      end
    end

    def rank(catalog: StrategyCatalog.new)
      backtested = catalog.by_status("backtested")
      @logger.info { "Ranking #{backtested.size} backtested strategies..." }

      backtested.each do |entry|
        wf_result = entry.dig(:backtest_results, :walk_forward)
        next unless wf_result

        # Gate check
        gate_result = Gatekeeper.evaluate(walk_forward_result: wf_result)

        # Score
        score_result = Scorer.score(walk_forward_result: wf_result)

        ranking = score_result.merge(gate_result)
        catalog.attach_ranking(entry[:id], ranking)

        @logger.info { "Ranked #{entry[:strategy][:name]}: score=#{score_result[:final_score]} status=#{gate_result[:status]}" }
        @memory << { phase: :rank, strategy_id: entry[:id], ranking: ranking }
      end

      catalog.ranked
    end

    def document(catalog: StrategyCatalog.new)
      passing = catalog.passing
      @logger.info { "Documenting #{passing.size} passing strategies..." }

      passing.each do |entry|
        card = StrategyCard.build(entry)
        MarkdownExporter.export(card)
        JsonExporter.export(card)

        # Optionally use LLM for richer documentation
        begin
          generator = StrategyGenerator.new
          llm_doc = generator.document(
            strategy: entry[:strategy],
            backtest_results: entry[:backtest_results]
          )
          catalog.attach_documentation(entry[:id], llm_doc) if llm_doc
        rescue StandardError => e
          @logger.warn { "LLM documentation failed for #{entry[:id]}: #{e.message}" }
        end
      end
    end

    private

    # Returns [final_result, steps] where final_result is nil when manual pipeline ran alone or after Ollama::Error.
    def run_with_executor(executor:, query:)
      steps = []
      return run_without_executor_tooling(query, steps) if executor.nil?

      run_executor_tool_loop(executor, query, steps)
    end

    def proposal_dedupe_key(candidate)
      base_name = candidate[:name].to_s.sub(/\s*\(offline template\)\s*\z/i, "").strip.downcase
      family = candidate[:family].to_s.downcase
      "#{family}:#{base_name}"
    end

    def run_without_executor_tooling(query, steps)
      @logger.warn { 'Ollama::Agent::Executor unavailable; running manual pipeline' }
      steps << { type: :executor_unavailable, content: 'manual_pipeline' }
      steps.concat(run_manual_pipeline(query))
      [nil, steps]
    end

    def run_executor_tool_loop(executor, query, steps)
      result = executor.run(system: AGENT_SYSTEM_PROMPT, user: build_initial_prompt(query))
      steps << { type: :executor_result, content: result }
      [result, steps]
    rescue Ollama::Error => e
      executor_failed_fallback(e, query, steps)
    end

    def executor_failed_fallback(error, query, steps)
      @logger.error { "Executor error: #{error.message}" }
      steps << { type: :error, content: error.message }
      steps.concat(run_manual_pipeline(query))
      [nil, steps]
    end

    def build_executor
      tools = {}
      @registry.all.each do |tool|
        tools[tool.name] = tool.callable
      end

      Ollama::Agent::Executor.new(@client, tools: tools)
    rescue NameError => e
      @logger.warn { "Ollama::Agent::Executor not available: #{e.message}. Using manual pipeline." }
      nil
    end

    def build_initial_prompt(query)
      <<~PROMPT
        Research task: #{query}

        Available instruments: #{StrategyBuilder.configuration.default_instruments.join(', ')}
        Available timeframes: #{StrategyBuilder.configuration.default_timeframes.join(', ')}

        Please:
        1. First list available instruments to confirm what's tradeable.
        2. Fetch MTF candles for the top 2-3 instruments.
        3. Compute features for each.
        4. Generate strategy candidates based on observed patterns.
        5. Report what you found and which strategies look promising.
      PROMPT
    end

    # Fallback: run the pipeline without the Executor tool loop.
    def run_manual_pipeline(_query)
      steps = []

      # Phase 1: Discover
      features = discover
      steps << { type: :discover, instruments: features.keys }

      # Phase 2: Propose
      candidates = propose(features_by_instrument: features)
      steps << { type: :propose, candidates_count: candidates.size }

      # Phase 3: Validate
      validate
      steps << { type: :validate, status: 'complete' }

      # Phase 4: Rank
      ranked = rank
      steps << { type: :rank, ranked_count: ranked.size }

      # Phase 5: Document
      document
      steps << { type: :document, status: 'complete' }

      steps
    end
  end
end
