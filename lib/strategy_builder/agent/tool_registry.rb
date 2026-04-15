# frozen_string_literal: true

module StrategyBuilder
  class ToolRegistry
    # Agent tools following the ToolRuntime pattern from ollama_agent:
    # - Small tool surface
    # - Explicit read/search/edit separation
    # - Sandboxed review flow
    #
    # Tool bodies live in Agent::ToolServices; this class is only registration + Ollama tool metadata.

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
      ) { |args| Agent::ToolServices::ListInstruments.call(args) }

      register("fetch_candles",
        description: "Fetch OHLCV candles for an instrument and timeframe",
        schema: { "type" => "object", "required" => %w[instrument timeframe days_back],
          "properties" => {
            "instrument" => { "type" => "string" },
            "timeframe" => { "type" => "string", "enum" => Configuration::VALID_TIMEFRAMES },
            "days_back" => { "type" => "integer", "minimum" => 1, "maximum" => 365 }
          }
        }
      ) { |args| Agent::ToolServices::FetchCandles.call(args) }

      register("fetch_mtf_candles",
        description: "Fetch candles across multiple timeframes for an instrument",
        schema: { "type" => "object", "required" => %w[instrument timeframes days_back],
          "properties" => {
            "instrument" => { "type" => "string" },
            "timeframes" => { "type" => "array", "items" => { "type" => "string" } },
            "days_back" => { "type" => "integer", "minimum" => 1, "maximum" => 365 }
          }
        }
      ) { |args| Agent::ToolServices::FetchMtfCandles.call(args) }
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
      ) { |args| Agent::ToolServices::ComputeFeatures.call(args) }
    end

    def register_strategy_tools
      register("list_templates",
        description: "List available strategy templates with their families and names",
        schema: { "type" => "object", "properties" => {} }
      ) { |args| Agent::ToolServices::ListTemplates.call(args) }

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
      ) { |args| Agent::ToolServices::GenerateStrategies.call(args) }

      register("list_catalog",
        description: "List all strategies in the catalog with their status and scores",
        schema: { "type" => "object", "properties" => {
          "status" => { "type" => "string" },
          "family" => { "type" => "string" }
        }}
      ) { |args| Agent::ToolServices::ListCatalog.call(args) }
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
      ) { |args| Agent::ToolServices::BacktestStrategy.call(args) }
    end

    def register_ranking_tools
      register("rank_strategies",
        description: "Rank all backtested strategies using composite scoring and gating",
        schema: { "type" => "object", "properties" => {
          "limit" => { "type" => "integer", "default" => 20 }
        }}
      ) { |args| Agent::ToolServices::RankStrategies.call(args) }
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
      ) { |args| Agent::ToolServices::ExportStrategyCard.call(args) }
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
