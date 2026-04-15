# frozen_string_literal: true

module StrategyBuilder
  class StrategyCatalog
    STATUSES = %w[proposed validated backtested ranked pass watchlist reject].freeze

    def initialize(storage_dir: nil)
      @storage_dir = storage_dir || File.join(StrategyBuilder.configuration.output_dir, "strategies")
      FileUtils.mkdir_p(@storage_dir)
      @catalog = load_catalog
    end

    def add(candidate, status: "proposed")
      id = generate_id(candidate)
      entry = {
        id: id,
        strategy: candidate,
        status: status,
        created_at: Time.now.utc.iso8601,
        updated_at: Time.now.utc.iso8601,
        backtest_results: nil,
        ranking: nil,
        documentation: nil
      }

      @catalog[id] = entry
      persist!
      id
    end

    def update_status(id, status)
      raise ValidationError, "Unknown status: #{status}" unless STATUSES.include?(status)
      raise ValidationError, "Strategy #{id} not found" unless @catalog.key?(id)

      @catalog[id][:status] = status
      @catalog[id][:updated_at] = Time.now.utc.iso8601
      persist!
    end

    def attach_backtest(id, results)
      raise ValidationError, "Strategy #{id} not found" unless @catalog.key?(id)

      prev = @catalog[id][:backtest_results]
      @catalog[id][:backtest_results] = merge_backtest_results(prev, results)
      @catalog[id][:status] = "backtested"
      @catalog[id][:updated_at] = Time.now.utc.iso8601
      persist!
    end

    def attach_ranking(id, ranking)
      raise ValidationError, "Strategy #{id} not found" unless @catalog.key?(id)

      @catalog[id][:ranking] = ranking
      @catalog[id][:status] = ranking[:status] || "ranked"
      @catalog[id][:updated_at] = Time.now.utc.iso8601
      persist!
    end

    def attach_documentation(id, doc)
      raise ValidationError, "Strategy #{id} not found" unless @catalog.key?(id)

      @catalog[id][:documentation] = doc
      @catalog[id][:updated_at] = Time.now.utc.iso8601
      persist!
    end

    def get(id)
      @catalog[id]
    end

    def all
      @catalog.values
    end

    def by_status(status)
      @catalog.values.select { |e| e[:status] == status }
    end

    def by_family(family)
      @catalog.values.select { |e| e[:strategy][:family] == family }
    end

    def ranked(limit: 20)
      @catalog.values
        .select { |e| e[:ranking] }
        .sort_by { |e| -(e[:ranking][:final_score] || 0) }
        .first(limit)
    end

    def passing
      by_status("pass")
    end

    def size
      @catalog.size
    end

    def clear!
      @catalog = {}
      persist!
    end

    private

    # Merges per-instrument walk-forward runs (validate loops all default_instruments).
    # Ranking reads :walk_forward and :metrics — we expose a combined view plus :instruments detail.
    def merge_backtest_results(previous, latest)
      instrument = latest[:instrument].to_s
      per = extract_instruments_map(previous)
      per[instrument] = {
        metrics: latest[:metrics],
        walk_forward: latest[:walk_forward],
        candle_count: latest[:candle_count]
      }

      canonical = build_ranking_walk_forward(per)
      {
        instruments: per,
        instrument: instrument,
        metrics: canonical[:aggregate],
        walk_forward: canonical,
        candle_count: per.values.sum { |v| v[:candle_count].to_i }
      }
    end

    def extract_instruments_map(previous)
      return {} unless previous.is_a?(Hash)
      return previous[:instruments].dup if previous[:instruments].is_a?(Hash)

      # Legacy single-instrument payload (before merge support)
      if previous[:instrument] && previous[:walk_forward]
        inst = previous[:instrument].to_s
        return {
          inst => {
            metrics: previous[:metrics],
            walk_forward: previous[:walk_forward],
            candle_count: previous[:candle_count]
          }
        }
      end

      {}
    end

    def build_ranking_walk_forward(per_instrument)
      wfs = per_instrument.values.map { |v| v[:walk_forward] }.compact
      return wfs.first if wfs.size <= 1

      aggregates = wfs.map { |wf| wf[:aggregate] }
      {
        aggregate: merge_aggregate_rows(aggregates),
        stability_score: mean_or_zero(wfs.map { |wf| wf[:stability_score] }),
        passes_walk_forward: wfs.all? { |wf| wf[:passes_walk_forward] },
        folds: wfs.flat_map { |wf| wf[:folds] || [] }
      }
    end

    def merge_aggregate_rows(aggs)
      return {} if aggs.nil? || aggs.empty?

      {
        oos_expectancy: mean_or_zero(aggs.map { |a| a[:oos_expectancy] }),
        oos_win_rate: mean_or_zero(aggs.map { |a| a[:oos_win_rate] }),
        oos_profit_factor: mean_or_zero(aggs.map { |a| a[:oos_profit_factor] }),
        oos_max_drawdown: aggs.map { |a| (a[:oos_max_drawdown] || 0).to_f }.max,
        oos_avg_r: mean_or_zero(aggs.map { |a| a[:oos_avg_r] }),
        oos_trade_count: aggs.sum { |a| (a[:oos_trade_count] || 0).to_i },
        is_expectancy: mean_or_zero(aggs.map { |a| a[:is_expectancy] }),
        is_profit_factor: mean_or_zero(aggs.map { |a| a[:is_profit_factor] }),
        avg_degradation: mean_or_zero(aggs.map { |a| a[:avg_degradation] })
      }
    end

    def mean_or_zero(values)
      vals = values.compact
      return 0.0 if vals.empty?

      (vals.sum / vals.size.to_f).round(4)
    end

    def generate_id(candidate)
      base = candidate[:name].to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/_+/, "_").strip
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      "#{base}_#{timestamp}"
    end

    def catalog_path
      File.join(@storage_dir, "catalog.json")
    end

    def persist!
      serializable = @catalog.transform_values { |v| stringify_keys_deep(v) }
      File.write(catalog_path, JSON.pretty_generate(serializable))
    end

    def load_catalog
      return {} unless File.exist?(catalog_path)

      raw = JSON.parse(File.read(catalog_path))
      raw.transform_values { |v| symbolize_keys_deep(v) }
    rescue JSON::ParserError => e
      StrategyBuilder.logger.error { "Corrupt catalog file: #{e.message}" }
      {}
    end

    def symbolize_keys_deep(obj)
      CandidateParser.symbolize_keys_deep(obj)
    end

    def stringify_keys_deep(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), m| m[k.to_s] = stringify_keys_deep(v) }
      when Array then obj.map { |v| stringify_keys_deep(v) }
      else obj
      end
    end
  end
end
