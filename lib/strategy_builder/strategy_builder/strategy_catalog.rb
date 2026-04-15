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

      @catalog[id][:backtest_results] = results
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
