# frozen_string_literal: true

module StrategyBuilder
  class CandidateParser
    # Parse LLM output into strategy candidate hashes.
    # Handles both single objects and arrays, strips markdown fences.
    def self.parse(raw_output)
      cleaned = strip_markdown_fences(raw_output)
      parsed = JSON.parse(cleaned)

      candidates = parsed.is_a?(Array) ? parsed : [parsed]
      candidates.map { |c| symbolize_keys_deep(c) }
    rescue JSON::ParserError => e
      StrategyBuilder.logger.error { "Failed to parse LLM output: #{e.message}" }
      StrategyBuilder.logger.debug { "Raw output: #{raw_output}" }
      []
    end

    def self.strip_markdown_fences(text)
      text = text.to_s.strip
      text = text.gsub(/\A```(?:json)?\s*\n?/, "").gsub(/\n?```\s*\z/, "")
      text.strip
    end

    def self.symbolize_keys_deep(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), memo|
          memo[k.to_sym] = symbolize_keys_deep(v)
        end
      when Array
        obj.map { |v| symbolize_keys_deep(v) }
      else
        obj
      end
    end
  end

  class CandidateValidator
    SCHEMA_PATH = File.expand_path("../agent/schemas/strategy_candidate.json", __dir__)

    REQUIRED_KEYS = %i[name family timeframes entry exit risk].freeze

    def initialize
      schema_data = JSON.parse(File.read(SCHEMA_PATH))
      @schema = JSONSchemer.schema(schema_data)
    rescue LoadError
      @schema = nil
      StrategyBuilder.logger.warn { "json_schemer not available, using basic validation only" }
    end

    # Validate a candidate hash. Returns { valid: bool, errors: [] }
    def validate(candidate)
      errors = []

      # Basic structural checks (always run)
      errors.concat(check_required_keys(candidate))
      errors.concat(check_entry(candidate[:entry]))
      errors.concat(check_exit(candidate[:exit]))
      errors.concat(check_risk(candidate[:risk]))
      errors.concat(check_partial_exits(candidate[:exit]))
      errors.concat(check_timeframes(candidate[:timeframes]))

      # JSON Schema validation (if available)
      if @schema
        string_keyed = stringify_keys_deep(candidate)
        schema_errors = @schema.validate(string_keyed).map { |e| e["error"] || e.to_s }
        errors.concat(schema_errors)
      end

      { valid: errors.empty?, errors: errors }
    end

    # Validate an array of candidates, returning only valid ones with their validation results.
    def filter_valid(candidates)
      candidates.filter_map do |candidate|
        result = validate(candidate)
        if result[:valid]
          { candidate: candidate, validation: result }
        else
          StrategyBuilder.logger.warn { "Rejected candidate '#{candidate[:name]}': #{result[:errors].join(', ')}" }
          nil
        end
      end
    end

    private

    def check_required_keys(candidate)
      missing = REQUIRED_KEYS.reject { |k| candidate.key?(k) && !candidate[k].nil? }
      missing.map { |k| "Missing required key: #{k}" }
    end

    def check_entry(entry)
      return ["Entry is nil"] if entry.nil?
      return ["Entry conditions missing"] unless entry[:conditions].is_a?(Array) && entry[:conditions].any?

      []
    end

    def check_exit(exit_config)
      return ["Exit is nil"] if exit_config.nil?
      return ["Exit targets missing"] unless exit_config[:targets].is_a?(Array) && exit_config[:targets].any?

      errors = []
      exit_config[:targets].each do |t|
        errors << "Target #{t} out of range (0.1-20.0)" unless t.is_a?(Numeric) && t >= 0.1 && t <= 20.0
      end
      errors
    end

    def check_risk(risk)
      return ["Risk is nil"] if risk.nil?
      return ["Stop logic missing"] if risk[:stop].nil? || risk[:stop].to_s.empty?
      return ["Position sizing missing"] if risk[:position_sizing].nil?

      errors = []
      if risk[:max_risk_percent] && risk[:max_risk_percent] > 3.0
        errors << "Max risk percent #{risk[:max_risk_percent]} exceeds 3.0% hard limit"
      end
      errors
    end

    def check_partial_exits(exit_config)
      return [] if exit_config.nil? || exit_config[:partial_exits].nil?

      parts = exit_config[:partial_exits]
      return [] unless parts.is_a?(Array)

      sum = parts.sum
      return ["Partial exits sum to #{sum}, must be ~1.0"] unless (sum - 1.0).abs < 0.05

      if exit_config[:targets] && parts.size != exit_config[:targets].size
        return ["Partial exits count (#{parts.size}) != targets count (#{exit_config[:targets].size})"]
      end

      []
    end

    def check_timeframes(timeframes)
      return ["Timeframes missing"] unless timeframes.is_a?(Array) && timeframes.any?

      valid = Configuration::VALID_TIMEFRAMES
      invalid = timeframes - valid
      invalid.map { |tf| "Invalid timeframe: #{tf}" }
    end

    def stringify_keys_deep(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), m| m[k.to_s] = stringify_keys_deep(v) }
      when Array
        obj.map { |v| stringify_keys_deep(v) }
      else
        obj
      end
    end
  end
end
