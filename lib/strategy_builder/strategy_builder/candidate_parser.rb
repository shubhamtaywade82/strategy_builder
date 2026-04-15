# frozen_string_literal: true

require 'json_schemer'

module StrategyBuilder
  class CandidateParser
    # Parse LLM output into strategy candidate hashes.
    # Handles both single objects and arrays, strips markdown fences, and extracts the first
    # balanced JSON array/object when the model wraps JSON in prose (so JSON.parse on the
    # whole body would fail).
    def self.parse(raw_output)
      cleaned = strip_markdown_fences(raw_output.to_s.strip)
      parsed = parse_json_loose(cleaned)
      return [] if parsed.nil?

      candidates = parsed.is_a?(Array) ? parsed : [parsed]
      candidates.filter_map do |c|
        next unless c.is_a?(Hash)

        symbolize_keys_deep(c)
      end
    rescue JSON::ParserError => e
      StrategyBuilder.logger.error { "Failed to parse LLM output: #{e.message}" }
      StrategyBuilder.logger.debug { "Raw output: #{raw_output}" }
      []
    end

    def self.parse_json_loose(text)
      JSON.parse(text)
    rescue JSON::ParserError
      fragment = extract_balanced_json_fragment(text)
      JSON.parse(fragment) if fragment
    end

    def self.strip_markdown_fences(text)
      text = text.to_s.strip
      text = text.gsub(/\A```(?:json)?\s*\n?/, "").gsub(/\n?```\s*\z/, "")
      text.strip
    end

    # First balanced JSON object or array starting at the earliest `{` or `[` (handles leading prose).
    def self.extract_balanced_json_fragment(text)
      return nil if text.nil? || text.empty?

      start_idx = text.index(/[\[{]/)
      return nil unless start_idx

      stack = []
      in_string = false
      escape = false

      i = start_idx
      while i < text.length
        ch = text.getbyte(i)

        if in_string
          if escape
            escape = false
          elsif ch == 92 # \
            escape = true
          elsif ch == 34 # "
            in_string = false
          end
        else
          case ch
          when 34 # "
            in_string = true
          when 123 # {
            stack << 125 # }
          when 91 # [
            stack << 93 # ]
          when 125, 93 # }, ]
            expected = stack.pop
            return nil if expected != ch

            return text[start_idx..i] if stack.empty?
          end
        end

        i += 1
      end

      nil
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
    PARTIAL_EXIT_SUM_TOLERANCE = 0.05

    def initialize
      schema_data = JSON.parse(File.read(SCHEMA_PATH))
      @schema = JSONSchemer.schema(schema_data)
    rescue LoadError, NameError => e
      @schema = nil
      StrategyBuilder.logger.warn { "JSON Schema unavailable (#{e.class}: #{e.message}); using basic validation only" }
    end

    # Validate a candidate hash. Returns { valid: bool, errors: [] }
    def validate(candidate)
      unless candidate.is_a?(Hash)
        return {
          valid: false,
          errors: ["Candidate must be a JSON object, got #{candidate.class.name} (#{candidate.inspect[0, 120]})"]
        }
      end

      repair_partial_exits!(candidate)

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
          label = candidate.is_a?(Hash) ? candidate[:name] : candidate.class.name
          StrategyBuilder.logger.warn { "Rejected candidate '#{label}': #{result[:errors].join(', ')}" }
          nil
        end
      end
    end

    private

    # LLMs often emit partial_exits that do not sum to 1.0 or do not match targets length.
    # Mutates candidate in place so validation and downstream backtests see a coherent schedule.
    def repair_partial_exits!(candidate)
      exit_cfg = candidate[:exit]
      return unless exit_cfg.is_a?(Hash)

      targets = exit_cfg[:targets]
      parts = exit_cfg[:partial_exits]
      return unless targets.is_a?(Array) && targets.any?
      return unless parts.is_a?(Array) && parts.any?

      n = targets.size
      nums = parts.filter_map do |p|
        Float(p)
      rescue ArgumentError, TypeError
        nil
      end
      return if nums.size != parts.size
      return if nums.any?(&:negative?) || nums.any? { |x| x.nan? || x.infinite? }

      repaired =
        if nums.size != n
          unit_equal_weights(n)
        elsif nums.sum <= 0
          unit_equal_weights(n)
        elsif (nums.sum - 1.0).abs < PARTIAL_EXIT_SUM_TOLERANCE
          snap_unit_weights(nums)
        else
          snap_unit_weights(nums.map { |w| w / nums.sum })
        end

      exit_cfg[:partial_exits] = repaired if repaired
    rescue ArgumentError, TypeError
      nil
    end

    def unit_equal_weights(n)
      snap_unit_weights(Array.new(n, 1.0 / n))
    end

    def snap_unit_weights(weights)
      w = weights.map(&:to_f)
      return nil if w.empty?

      w = w.map { |x| x.round(8) }
      drift = 1.0 - w.sum
      w[-1] = (w[-1] + drift).round(8)
      w
    end

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
      unless (sum - 1.0).abs < PARTIAL_EXIT_SUM_TOLERANCE
        return ["Partial exits sum to #{sum}, must be ~1.0"]
      end

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
