# frozen_string_literal: true

module StrategyBuilder
  # Service objects for agent tools (ToolRegistry stays a thin map + schemas).
  module Agent
    module ToolServices
      module ListInstruments
        module_function

        def call(args)
          loader = InstrumentLoader.new
          loader.tradeable_pairs(
            margin_currency: args["margin_currency"] || "USDT",
            min_volume_usdt: args["min_volume_usdt"] || 100_000
          )
        end
      end

      module FetchCandles
        module_function

        def call(args)
          loader = CandleLoader.new
          from = Time.now - (args["days_back"] * 86_400)
          candles = loader.fetch(
            instrument: args["instrument"],
            timeframe: args["timeframe"],
            from: from
          )
          { count: candles.size, first_ts: candles.first&.dig(:timestamp), last_ts: candles.last&.dig(:timestamp) }
        end
      end

      module FetchMtfCandles
        module_function

        def call(args)
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

      module ComputeFeatures
        module_function

        def call(args)
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

      module ListTemplates
        module_function

        def call(_args)
          StrategyTemplates.all.map { |t| { name: t[:name], family: t[:family], timeframes: t[:timeframes] } }
        end
      end

      module GenerateStrategies
        module_function

        def call(args)
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

          catalog = StrategyCatalog.new
          candidates.map do |c|
            id = catalog.add(c)
            { id: id, name: c[:name], family: c[:family], status: :proposed }
          end
        end
      end

      module ListCatalog
        module_function

        def call(args)
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

      module BacktestStrategy
        module_function

        def call(args)
          catalog = StrategyCatalog.new
          entry = catalog.get(args["strategy_id"])
          raise Error, "Strategy not found: #{args['strategy_id']}" unless entry

          strategy = entry[:strategy]
          loader = CandleLoader.new
          from = Time.now - (args["days_back"] * 86_400)
          tf = strategy[:timeframes]
          timeframes = (tf.is_a?(Array) && !tf.empty?) ? tf : StrategyBuilder.configuration.default_timeframes
          primary_tf = timeframes.last || "5m"
          mtf = loader.fetch_mtf(instrument: args["instrument"], timeframes: timeframes, from: from)
          candles = mtf[primary_tf] || []

          raise Error, "Insufficient data: #{candles.size} candles" if candles.size < 200

          signal_gen = SignalEvaluator.build(strategy, mtf_candles: mtf)

          engine = BacktestEngine.new
          wf = WalkForward.new(engine: engine)
          wf_result = wf.run(
            strategy: strategy,
            candles: candles,
            signal_generator: signal_gen,
            folds: args["folds"] || 5,
            mtf_candles: mtf
          )

          wf_result[:regime_slices] = wf.volatility_regime_slices(
            strategy: strategy,
            candles: candles,
            signal_generator: signal_gen,
            mtf_candles: mtf
          )
          wf_result[:anchored_holdout] = wf.anchored_holdout(
            strategy: strategy,
            candles: candles,
            signal_generator: signal_gen,
            mtf_candles: mtf
          )

          session_results = wf.session_analysis(
            strategy: strategy,
            candles: candles,
            signal_generator: signal_gen,
            mtf_candles: mtf
          )

          robustness_result = StrategyBuilder::Robustness.analyze(
            strategy: strategy,
            candles: candles,
            engine: engine,
            mtf_candles: mtf,
            signal_generator_factory: lambda { |mutated|
              SignalEvaluator.build(mutated, mtf_candles: mtf)
            }
          )

          catalog.attach_backtest(entry[:id], {
            metrics: wf_result[:aggregate],
            walk_forward: wf_result,
            session_results: session_results,
            robustness_result: robustness_result,
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

      module RankStrategies
        module_function

        def call(args)
          catalog = StrategyCatalog.new
          limit = args["limit"] || 20

          catalog.by_status("backtested").each do |entry|
            wf_result = entry.dig(:backtest_results, :walk_forward)
            next unless wf_result

            gate_result = Gatekeeper.evaluate(walk_forward_result: wf_result)
            session_results = entry.dig(:backtest_results, :session_results)
            robustness_result = entry.dig(:backtest_results, :robustness_result)
            score_result = Scorer.score(
              walk_forward_result: wf_result,
              session_results: session_results,
              robustness_result: robustness_result
            )
            catalog.attach_ranking(entry[:id], score_result.merge(gate_result))
          end

          catalog.ranked(limit: limit).map do |entry|
            {
              id: entry[:id],
              name: entry[:strategy][:name],
              score: entry.dig(:ranking, :final_score),
              status: entry[:status]
            }
          end
        end
      end

      module ExportStrategyCard
        module_function

        def call(args)
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
    end
  end
end
