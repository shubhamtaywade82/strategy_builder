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
      max_steps: nil,
      catalog_factory: -> { StrategyCatalog.new },
      candle_loader_factory: -> { CandleLoader.new },
      backtest_engine_factory: -> { BacktestEngine.new },
      walk_forward_factory: ->(engine) { WalkForward.new(engine: engine) },
      strategy_generator_factory: -> { StrategyGenerator.new },
      desk_pipeline_factory: nil,
      discover_phase: nil,
      validate_phase: nil,
      parallel_instrument_max: nil
    )
      @client = client
      @max_steps = max_steps || StrategyBuilder.configuration.max_agent_iterations
      @logger = StrategyBuilder.logger
      @memory = []
      @step_count = 0
      @catalog_factory = catalog_factory
      @strategy_generator_factory = strategy_generator_factory
      @desk_pipeline_factory = desk_pipeline_factory || -> { Agent::DeskPipeline.new(client: client) }
      pmax = parallel_instrument_max || StrategyBuilder.configuration.parallel_instrument_max
      @discover_phase = discover_phase || Agent::DiscoverPhase.new(
        logger: @logger,
        candle_loader_factory: candle_loader_factory,
        parallel_max: pmax
      )
      @validate_phase = validate_phase || Agent::ValidatePhase.new(
        logger: @logger,
        candle_loader_factory: candle_loader_factory,
        backtest_engine_factory: backtest_engine_factory,
        walk_forward_factory: walk_forward_factory,
        parallel_max: pmax
      )
    end

    attr_reader :memory

    class << self
      def phase_registry
        @phase_registry ||= {
          discover: ->(agent, **kw) { agent.discover(**kw) },
          propose: ->(agent, **kw) { agent.propose(**kw) },
          validate: ->(agent, **kw) { agent.validate(**kw) },
          rank: ->(agent, **kw) { agent.rank(**kw) },
          document: ->(agent, **kw) { agent.document(**kw) }
        }
      end

      def register_phase(phase, &handler)
        phase_registry[phase.to_sym] = handler
      end
    end

    # Run the full research pipeline (deterministic Ruby phases only).
    # query: logged for traceability; the catalog outcome is the source of truth.
    # Returns: { steps: [...], final_result: nil, strategies_found: Int, passing_strategies: Int }
    def run(query:)
      @logger.info { "Agent starting (deterministic pipeline): #{query}" }
      catalog = @catalog_factory.call
      steps = run_manual_pipeline(query)
      {
        steps: steps,
        final_result: nil,
        strategies_found: catalog.size,
        passing_strategies: catalog.passing.size
      }
    end

    # Run a specific phase of the pipeline (for granular control).
    # Use AgentLoop.register_phase(:custom, &:handler) to extend without editing this class.
    def run_phase(phase, **kwargs)
      handler = self.class.phase_registry.fetch(phase) do
        raise ArgumentError, "Unknown phase: #{phase}"
      end
      handler.call(self, **kwargs)
    end

    # --- Individual pipeline phases (for manual/step-by-step execution) ---

    def discover(instruments: nil, timeframes: nil, days_back: 30)
      instruments ||= StrategyBuilder.configuration.default_instruments
      timeframes ||= StrategyBuilder.configuration.default_timeframes

      @discover_phase.execute(
        instruments: instruments,
        timeframes: timeframes,
        days_back: days_back,
        memory: @memory
      )
    end

    def propose(features_by_instrument:, mode: :generate)
      catalog = @catalog_factory.call
      all_candidates = []
      seen_proposal_keys = {}

      features_by_instrument.each do |instrument, features|
        @logger.info { "Proposing strategies for #{instrument} via DeskPipeline (mode: #{mode})..." }

        candidates = if mode == :mutate
                       @strategy_generator_factory.call.mutate(features: features)
                     else
                       @desk_pipeline_factory.call.run(instrument: instrument, features: features)
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

    def validate(catalog: nil, instruments: nil, days_back: 90)
      catalog ||= @catalog_factory.call
      instruments ||= StrategyBuilder.configuration.default_instruments

      @validate_phase.execute(
        catalog: catalog,
        instruments: instruments,
        days_back: days_back,
        memory: @memory
      )
    end

    def rank(catalog: nil)
      catalog ||= @catalog_factory.call
      backtested = catalog.by_status("backtested")
      @logger.info { "Ranking #{backtested.size} backtested strategies..." }

      backtested.each do |entry|
        wf_result = entry.dig(:backtest_results, :walk_forward)
        next unless wf_result

        # Gate check
        gate_result = Gatekeeper.evaluate(walk_forward_result: wf_result)

        # Score
        score_result = Scorer.score(
          walk_forward_result: wf_result,
          session_results: entry.dig(:backtest_results, :session_results),
          robustness_result: entry.dig(:backtest_results, :robustness_result)
        )

        ranking = score_result.merge(gate_result)
        catalog.attach_ranking(entry[:id], ranking)

        @logger.info { "Ranked #{entry[:strategy][:name]}: score=#{score_result[:final_score]} status=#{gate_result[:status]}" }
        @memory << { phase: :rank, strategy_id: entry[:id], ranking: ranking }
      end

      catalog.ranked
    end

    def document(catalog: nil)
      catalog ||= @catalog_factory.call
      passing = catalog.passing
      @logger.info { "Documenting #{passing.size} passing strategies..." }

      passing.each do |entry|
        card = StrategyCard.build(entry)
        MarkdownExporter.export(card)
        JsonExporter.export(card)

        # Optionally use LLM for richer documentation
        begin
          generator = @strategy_generator_factory.call
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

    def proposal_dedupe_key(candidate)
      base_name = candidate[:name].to_s.sub(/\s*\((?:offline|mutated) template\)\s*\z/i, "").strip.downcase
      family = candidate[:family].to_s.downcase
      "#{family}:#{base_name}"
    end

    # Pipeline execution without LLM tool loops.
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
