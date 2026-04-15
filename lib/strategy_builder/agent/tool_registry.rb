# frozen_string_literal: true

module StrategyBuilder
  class ToolRegistry
    # Agent tools following the ToolRuntime pattern from ollama_agent:
    # - Small tool surface
    # - Explicit read/search/edit separation
    # - Sandboxed review flow

    Tool = Struct.new(:name, :description, :schema, :callable, keyword_init: true)

    def initialize
      @tools = {}
      register_default_tools
    end

    def register(name, description:, schema:, &block)
      @tools[name] = Tool.new(
        name: name,
        description: description,
        schema: schema,
        callable: block
      )
    end

    def fetch(name)
      @tools.fetch(name) { raise Error, "Unknown tool: #{name}" }
    end

    def all
      @tools.values
    end

    def names
      @tools.keys
    end

    # Convert to Ollama tool format for Executor.
    def to_ollama_tools
      @tools.transform_values do |tool|
        {
          tool: build_ollama_tool(tool),
          callable: tool.callable
        }
      end
    end

    private

    def register_default_tools
      register_data_tools
      register_feature_tools
      register_strategy_tools
      register_backtest_tools
      register_ranking_tools
      register_doc_tools
    end

    def register_data_tools
      register("list_instruments",
        description: "List active CoinDCX futures instruments with volume data",
        schema: { "type" => "object", "properties" => {
          "margin_currency" => { "type" => "string", "default" => "USDT" },
          "min_volume_usdt" => { "type" => "number", "default" => 100_000 }
        }}
      ) do |args|
        loader = InstrumentLoader.new
        loader.tradeable_pairs(
          margin_currency: args["margin_currency"] || "USDT",
          min_volume_usdt: args["min_volume_usdt"] || 100_000
        )
      end

      register("fetch_candles",
        description: "Fetch OHLCV candles for an instrument and timeframe",
        schema: { "type" => "object", "required" => %w[instrument timeframe days_back],
          "properties" => {
            "instrument" => { "type" => "string" },
            "timeframe" => { "type" => "string", "enum" => Configuration::VALID_TIMEFRAMES },
            "days_back" => { "type" => "integer", "minimum" => 1, "maximum" => 365 }
          }
        }
      ) do |args|
        loader = CandleLoader.new
        from = Time.now - (args["days_back"] * 86_400)
        candles = loader.fetch(
          instrument: args["instrument"],
          timeframe: args["timeframe"],
          from: from
        )
        { count: candles.size, first_ts: candles.first&.dig(:timestamp), last_ts: candles.last&.dig(:timestamp) }
      end

      register("fetch_mtf_candles",
        description: "Fetch candles across multiple timeframes for an instrument",
        schema: { "type" => "object", "required" => %w[instrument timeframes days_back],
          "properties" => {
            "instrument" => { "type" => "string" },
            "timeframes" => { "type" => "array", "items" => { "type" => "string" } },
            "days_back" => { "type" => "integer", "minimum" => 1, "maximum" => 365 }
          }
        }
      ) do |args|
        loader = CandleLoader.new
        from = Time.now - (args["days_back"] * 86_400)
        mtf = loader.fetch_mtf(
          instrument: args["instrument"],
          timeframes: args["timeframes"],
          from: from
        )
        mtf.transform_values { |c| { count: c.size } }
      end
    end

    def register_feature_tools
      register("compute_features",
        description: "Compute full feature set for an instrument's MTF candle data. Returns trend, volatility, structure, volume, momentum profiles.",
        schema: { "type" => "object", "required" => %w[instrument timeframes days_back],
          "properties" => {
            "instrument" => { "type" => "string" },
            "timeframes" => { "type" => "array", "items" => { "type" => "string" } },
            "days_back" => { "type" => "integer", "minimum" => 7, "maximum" => 365 }
          }
        }
      ) do |args|
        loader = CandleLoader.new
        from = Time.now - (args["days_back"] * 86_400)
        mtf = loader.fetch_mtf(
          instrument: args["instrument"],
          timeframes: args["timeframes"],
          from: from
        )
        FeatureBuilder.build(instrument: args["instrument"], mtf_candles: mtf)
      end
    end

    def register_strategy_tools
      register("list_templates",
        description: "List available strategy templates with their families and names",
        schema: { "type" => "object", "properties" => {} }
      ) do |_args|
        StrategyTemplates.all.map { |t| { name: t[:name], family: t[:family], timeframes: t[:timeframes] } }
      end

      register("generate_strategies",
        description: "Use the LLM thinking model to generate new strategy candidates from feature data",
        schema: { "type" => "object", "required" => %w[instrument timeframes days_back],
          "properties" => {
            "instrument" => { "type" => "string" },
            "timeframes" => { "type" => "array", "items" => { "type" => "string" } },
            "days_back" => { "type" => "integer", "minimum" => 7, "maximum" => 365 },
            "mode" => { "type" => "string", "enum" => %w[generate mutate], "default" => "generate" }
          }
        }
      ) do |args|
        loader = CandleLoader.new
        from = Time.now - (args["days_back"] * 86_400)
        mtf = loader.fetch_mtf(instrument: args["instrument"], timeframes: args["timeframes"], from: from)
        features = FeatureBuilder.build(instrument: args["instrument"], mtf_candles: mtf)

        generator = StrategyGenerator.new
        mode = args["mode"]&.to_sym || :generate

        candidates = if mode == :mutate
                       generator.mutate(features: features)
                     else
                       generator.generate(features: features)
                     end

        candidates.map { |c| { name: c[:name], family: c[:family], status: :proposed } }
      end

      register("list_catalog",
        description: "List all strategies in the catalog with their status and scores",
        schema: { "type" => "object", "properties" => {
          "status" => { "type" => "string" },
          "family" => { "type" => "string" }
        }}
      ) do |args|
        catalog = StrategyCatalog.new
        entries = if args["status"]
                    catalog.by_status(args["status"])
                  elsif args["family"]
                    catalog.by_family(args["family"])
                  else
                    catalog.all
                  end

        entries.map { |e| { id: e[:id], name: e[:strategy][:name], status: e[:status], score: e.dig(:ranking, :final_score) } }
      end
    end

    def register_backtest_tools
      register("backtest_strategy",
        description: "Run walk-forward backtest on a strategy from the catalog",
        schema: { "type" => "object", "required" => %w[strategy_id instrument days_back],
          "properties" => {
            "strategy_id" => { "type" => "string" },
            "instrument" => { "type" => "string" },
            "days_back" => { "type" => "integer", "minimum" => 30, "maximum" => 365 },
            "folds" => { "type" => "integer", "minimum" => 3, "maximum" => 10, "default" => 5 }
          }
        }
      ) do |args|
        catalog = StrategyCatalog.new
        entry = catalog.get(args["strategy_id"])
        raise Error, "Strategy not found: #{args['strategy_id']}" unless entry

        strategy = entry[:strategy]
        signal_gen = SignalGeneratorFactory.build(strategy)

        loader = CandleLoader.new
        from = Time.now - (args["days_back"] * 86_400)
        primary_tf = strategy[:timeframes]&.last || "5m"
        candles = loader.fetch(instrument: args["instrument"], timeframe: primary_tf, from: from)

        raise Error, "Insufficient data: #{candles.size} candles" if candles.size < 200

        engine = BacktestEngine.new
        wf = WalkForward.new(engine: engine)
        wf_result = wf.run(
          strategy: strategy,
          candles: candles,
          signal_generator: signal_gen,
          folds: args["folds"] || 5
        )

        catalog.attach_backtest(entry[:id], {
          metrics: wf_result[:aggregate],
          walk_forward: wf_result,
          instrument: args["instrument"],
          candle_count: candles.size
        })

        {
          strategy_id: args["strategy_id"],
          status: "backtested",
          oos_expectancy: wf_result[:aggregate][:oos_expectancy],
          oos_profit_factor: wf_result[:aggregate][:oos_profit_factor],
          stability: wf_result[:stability_score],
          passes: wf_result[:passes_walk_forward]
        }
      end
    end

    def register_ranking_tools
      register("rank_strategies",
        description: "Rank all backtested strategies using composite scoring and gating",
        schema: { "type" => "object", "properties" => {
          "limit" => { "type" => "integer", "default" => 20 }
        }}
      ) do |args|
        catalog = StrategyCatalog.new
        catalog.ranked(limit: args["limit"] || 20).map do |entry|
          {
            id: entry[:id],
            name: entry[:strategy][:name],
            score: entry.dig(:ranking, :final_score),
            status: entry[:status]
          }
        end
      end
    end

    def register_doc_tools
      register("export_strategy_card",
        description: "Generate and export a strategy card document for a ranked strategy",
        schema: { "type" => "object", "required" => %w[strategy_id format],
          "properties" => {
            "strategy_id" => { "type" => "string" },
            "format" => { "type" => "string", "enum" => %w[markdown json both] }
          }
        }
      ) do |args|
        catalog = StrategyCatalog.new
        entry = catalog.get(args["strategy_id"])
        raise Error, "Strategy not found" unless entry

        card = StrategyCard.build(entry)
        paths = []

        if %w[markdown both].include?(args["format"])
          paths << MarkdownExporter.export(card)
        end

        if %w[json both].include?(args["format"])
          paths << JsonExporter.export(card)
        end

        { exported: paths }
      end
    end

    def build_ollama_tool(tool)
      Ollama::Tool.new(
        type: "function",
        function: Ollama::Tool::Function.new(
          name: tool.name,
          description: tool.description,
          parameters: Ollama::Tool::Function::Parameters.new(
            type: "object",
            properties: build_properties(tool.schema["properties"] || {}),
            required: tool.schema["required"] || []
          )
        )
      )
    rescue NameError
      # Fallback if Ollama::Tool classes aren't available
      { name: tool.name, description: tool.description, parameters: tool.schema }
    end

    def build_properties(props)
      props.transform_values do |spec|
        Ollama::Tool::Function::Parameters::Property.new(
          type: spec["type"],
          description: spec["description"] || ""
        )
      end
    rescue NameError
      props
    end
  end
end
