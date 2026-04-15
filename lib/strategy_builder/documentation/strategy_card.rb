# frozen_string_literal: true

module StrategyBuilder
  class StrategyCard
    # Build a strategy card from a catalog entry with backtest and ranking data.
    # Can be enriched by LLM for narrative documentation, or used as-is for structured output.
    def self.build(catalog_entry)
      strategy = catalog_entry[:strategy]
      metrics = catalog_entry.dig(:backtest_results, :metrics) || {}
      ranking = catalog_entry[:ranking] || {}
      doc = catalog_entry[:documentation] || {}

      {
        id: catalog_entry[:id],
        name: strategy[:name],
        family: strategy[:family],
        status: catalog_entry[:status],
        summary: doc[:summary] || auto_summary(strategy, metrics),
        edge_explanation: doc[:edge_explanation] || auto_edge(strategy),
        best_conditions: {
          timeframes: strategy[:timeframes],
          sessions: strategy[:session] || ["any"],
          instruments: strategy.dig(:filters, :instruments) || ["all"],
          regimes: strategy.dig(:filters, :required_regime) || ["any"]
        },
        entry_checklist: strategy.dig(:entry, :conditions) || [],
        exit_plan: {
          targets_r: strategy.dig(:exit, :targets),
          partial_exits: strategy.dig(:exit, :partial_exits),
          trail: strategy.dig(:exit, :trail),
          time_stop: strategy.dig(:exit, :time_stop_candles)
        },
        risk_model: {
          stop: strategy.dig(:risk, :stop),
          sizing: strategy.dig(:risk, :position_sizing),
          max_risk: strategy.dig(:risk, :max_risk_percent)
        },
        invalidation: strategy[:invalidation] || [],
        performance: {
          expectancy: metrics[:expectancy],
          win_rate: metrics[:win_rate],
          profit_factor: metrics[:profit_factor],
          max_drawdown: metrics[:max_drawdown],
          avg_r: metrics[:avg_r],
          trade_count: metrics[:trade_count],
          sharpe: metrics[:sharpe_ratio]
        },
        ranking_score: ranking[:final_score],
        component_scores: ranking[:component_scores],
        failure_modes: doc[:failure_modes] || auto_failure_modes(strategy),
        parameter_bounds: strategy[:parameter_ranges] || {},
        created_at: catalog_entry[:created_at],
        updated_at: catalog_entry[:updated_at]
      }
    end

    private_class_method def self.auto_summary(strategy, metrics)
      parts = []
      parts << "#{strategy[:name]} (#{strategy[:family]})"
      parts << "trades on #{strategy[:timeframes]&.join('/')}" if strategy[:timeframes]
      parts << "during #{strategy[:session]&.join('/')} sessions" if strategy[:session]

      if metrics[:expectancy]
        parts << "with #{metrics[:expectancy].round(4)} expectancy"
        parts << "and #{(metrics[:win_rate] * 100).round(1)}% win rate" if metrics[:win_rate]
      end

      parts.join(" ")
    end

    private_class_method def self.auto_edge(strategy)
      conditions = strategy.dig(:entry, :conditions) || []
      "Enters on confluence of: #{conditions.join(', ')}. " \
        "Risk managed with #{strategy.dig(:risk, :stop)} stop and #{strategy.dig(:risk, :position_sizing)} sizing."
    end

    private_class_method def self.auto_failure_modes(strategy)
      modes = []
      modes.concat(strategy[:invalidation] || [])
      modes << "low_liquidity_sessions" unless strategy[:session]&.include?("any")
      modes << "regime_mismatch" if strategy.dig(:filters, :required_regime)
      modes
    end
  end

  class MarkdownExporter
    def self.export(strategy_card, output_dir: nil)
      output_dir ||= File.join(StrategyBuilder.configuration.output_dir, "reports")
      FileUtils.mkdir_p(output_dir)

      filename = "#{strategy_card[:id] || 'unnamed'}.md"
      path = File.join(output_dir, filename)

      content = render(strategy_card)
      File.write(path, content)
      StrategyBuilder.logger.info { "Exported strategy card: #{path}" }
      path
    end

    def self.render(card)
      <<~MD
        # Strategy Card: #{card[:name]}

        **Family:** #{card[:family]}
        **Status:** #{card[:status]}
        **Score:** #{card[:ranking_score]&.round(3) || 'N/A'}

        ## Summary

        #{card[:summary]}

        ## Edge Explanation

        #{card[:edge_explanation]}

        ## Best Conditions

        - **Timeframes:** #{card.dig(:best_conditions, :timeframes)&.join(', ')}
        - **Sessions:** #{card.dig(:best_conditions, :sessions)&.join(', ')}
        - **Regimes:** #{card.dig(:best_conditions, :regimes)&.join(', ')}

        ## Entry Checklist

        #{(card[:entry_checklist] || []).each_with_index.map { |c, i| "#{i + 1}. #{c}" }.join("\n")}

        ## Exit Plan

        - **Targets (R):** #{card.dig(:exit_plan, :targets_r)&.join(', ')}
        - **Partial Exits:** #{card.dig(:exit_plan, :partial_exits)&.join(', ')}
        - **Trail:** #{card.dig(:exit_plan, :trail)}
        - **Time Stop:** #{card.dig(:exit_plan, :time_stop) || 'None'}

        ## Risk Model

        - **Stop:** #{card.dig(:risk_model, :stop)}
        - **Sizing:** #{card.dig(:risk_model, :sizing)}
        - **Max Risk:** #{card.dig(:risk_model, :max_risk)}%

        ## Performance

        | Metric | Value |
        |--------|-------|
        | Expectancy | #{card.dig(:performance, :expectancy)&.round(4)} |
        | Win Rate | #{card.dig(:performance, :win_rate) && "#{(card.dig(:performance, :win_rate) * 100).round(1)}%"} |
        | Profit Factor | #{card.dig(:performance, :profit_factor)&.round(2)} |
        | Max Drawdown | #{card.dig(:performance, :max_drawdown)&.round(4)} |
        | Avg R | #{card.dig(:performance, :avg_r)&.round(2)} |
        | Trade Count | #{card.dig(:performance, :trade_count)} |
        | Sharpe | #{card.dig(:performance, :sharpe)&.round(2)} |

        ## Invalidation Rules

        #{(card[:invalidation] || []).map { |r| "- #{r}" }.join("\n")}

        ## Failure Modes

        #{(card[:failure_modes] || []).map { |f| "- #{f}" }.join("\n")}

        ## Parameter Bounds

        #{(card[:parameter_bounds] || {}).map { |k, v| "- **#{k}:** #{v}" }.join("\n")}

        ---
        *Generated: #{card[:updated_at] || Time.now.utc.iso8601}*
      MD
    end
  end

  class JsonExporter
    def self.export(strategy_card, output_dir: nil)
      output_dir ||= File.join(StrategyBuilder.configuration.output_dir, "strategies")
      FileUtils.mkdir_p(output_dir)

      filename = "#{strategy_card[:id] || 'unnamed'}.json"
      path = File.join(output_dir, filename)

      File.write(path, JSON.pretty_generate(strategy_card))
      StrategyBuilder.logger.info { "Exported strategy JSON: #{path}" }
      path
    end

    def self.export_ranking_table(catalog)
      ranked = catalog.ranked
      table = ranked.map do |entry|
        card = StrategyCard.build(entry)
        {
          rank: nil, # assigned below
          id: card[:id],
          name: card[:name],
          family: card[:family],
          score: card[:ranking_score],
          expectancy: card.dig(:performance, :expectancy),
          profit_factor: card.dig(:performance, :profit_factor),
          win_rate: card.dig(:performance, :win_rate),
          trades: card.dig(:performance, :trade_count),
          status: card[:status]
        }
      end

      table.each_with_index { |row, i| row[:rank] = i + 1 }
      table
    end
  end
end
