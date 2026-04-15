# frozen_string_literal: true

module StrategyBuilder
  class PromptBuilder
    SCHEMA_PATH = File.expand_path("../agent/schemas/strategy_candidate.json", __dir__)

    # Static rules + families. Runtime `system_prompt` appends registered entry condition IDs.
    SYSTEM_PROMPT_STATIC = <<~SYSTEM
      You are a quantitative strategy researcher for cryptocurrency futures markets.
      Your role is to propose trading strategy candidates based on computed market features.

      RULES:
      1. You MUST output valid JSON matching the provided schema. No prose, no markdown, no explanation outside the JSON.
      2. Every strategy MUST have concrete, testable entry conditions — not vague descriptions.
      3. Every strategy MUST have explicit stop-loss logic, position sizing, and exit targets.
      4. You MUST NOT invent indicators or features not present in the provided feature data.
      5. You MUST specify parameter_ranges for every tunable parameter so the backtester can optimize.
      6. Strategies must be realistic for crypto futures: consider 24/7 markets, session-based liquidity, and fee impact.
      7. Prefer strategies with clear invalidation conditions — a strategy that cannot be invalidated is not a strategy.
      8. When mutating templates, change at most 3 parameters or conditions at a time. Do not reinvent the template.
      9. exit.partial_exits MUST have the same length as exit.targets, each value in (0,1], and the values MUST sum to exactly 1.0 (position fractions closed at each R target).
      10. entry.conditions MUST be a JSON array of strings where each string is EXACTLY one identifier from the ALLOWED_ENTRY_CONDITION_IDS list appended below. Use snake_case identifiers only — no English sentences, no dotted feature paths (e.g. mtf_alignment...), no comparisons or pseudo-code.

      STRATEGY FAMILIES YOU MAY USE:
      - session_breakout: Trade breakouts of session ranges (Asia, London, NY)
      - session_mean_reversion: Fade moves at session extremes
      - mtf_pullback: Enter on lower-TF pullback within higher-TF trend
      - compression_breakout: Enter on volatility expansion after compression
      - failed_breakout: Fade false breakouts with structure confirmation
      - vwap_reclaim: Enter on VWAP/MA reclaim with structure shift
      - volume_continuation: Enter on volume burst continuation
      - atr_expansion: Enter on ATR expansion follow-through
      - structure_shift: Enter on market structure shift (MSS)
      - custom: Novel combination (must justify why existing families don't fit)
    SYSTEM

    # @deprecated Prefer {.system_prompt} for LLM calls (includes dynamic condition ID list).
    SYSTEM_PROMPT = SYSTEM_PROMPT_STATIC

    def self.system_prompt
      "#{SYSTEM_PROMPT_STATIC}#{entry_conditions_contract_appendix}"
    end

    def self.entry_conditions_contract_appendix
      ids = ConditionRegistry.condition_ids
      <<~APPENDIX

        ALLOWED_ENTRY_CONDITION_IDS (comma-separated; each entry.conditions[] value must be one of these, verbatim):
        #{ids.join(', ')}

        EXAMPLE_VALID_BUNDLES_BY_FAMILY (copy identifiers only from the list above; combine 1–8 conditions per strategy):
        #{example_condition_bundles_by_family}
      APPENDIX
    end

    def self.example_condition_bundles_by_family
      seen = {}
      lines = []
      StrategyTemplates.all.each do |t|
        fam = t[:family].to_s
        next if seen[fam]

        conds = t.dig(:entry, :conditions)
        next if conds.nil? || conds.empty?

        seen[fam] = true
        lines << "- #{fam}: #{conds.join(', ')}"
      end
      lines.join("\n")
    end

    def self.entry_conditions_snippet_for_task_prompt
      <<~SNIPPET

        ALLOWED_ENTRY_CONDITION_IDS (entry.conditions[] must use only these strings, verbatim):
        #{ConditionRegistry.condition_ids.join(', ')}

        EXAMPLE_VALID_BUNDLES_BY_FAMILY:
        #{example_condition_bundles_by_family}
      SNIPPET
    end

    # Ollama /api/generate response schema: constrains entry.conditions to registered IDs.
    def self.strategy_candidates_generate_schema
      ids = ConditionRegistry.condition_ids
      {
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 8,
        "items" => {
          "type" => "object",
          "required" => %w[name family timeframes entry exit risk],
          "additionalProperties" => true,
          "properties" => {
            "entry" => {
              "type" => "object",
              "required" => ["conditions"],
              "additionalProperties" => true,
              "properties" => {
                "conditions" => {
                  "type" => "array",
                  "minItems" => 1,
                  "maxItems" => 8,
                  "items" => { "type" => "string", "enum" => ids }
                },
                "direction" => {
                  "type" => "string",
                  "enum" => %w[long short both]
                }
              }
            }
          }
        }
      }
    end

    # Build a prompt for generating new strategy candidates from features.
    def self.generation_prompt(features:, templates:, mode: :generate)
      case mode
      when :generate
        new_strategy_prompt(features: features, templates: templates)
      when :mutate
        mutation_prompt(features: features, templates: templates)
      when :critique
        critique_prompt(features: features, templates: templates)
      else
        raise ArgumentError, "Unknown mode: #{mode}"
      end
    end

    def self.new_strategy_prompt(features:, templates:)
      <<~PROMPT
        TASK: Analyze the following market features and propose 3 new strategy candidates.

        MARKET FEATURES:
        #{JSON.pretty_generate(features)}

        EXISTING TEMPLATE FAMILIES (for reference — do not duplicate, but you may derive from them):
        #{templates.map { |t| "- #{t[:name]} (#{t[:family]})" }.join("\n")}
        #{entry_conditions_snippet_for_task_prompt}
        INSTRUCTIONS:
        1. Study the feature data: trend alignment, volatility regime, session patterns, structure, volume behavior.
        2. Identify edges: What patterns in this data suggest a repeatable trading opportunity?
        3. For each edge, construct a strategy candidate with ALL required fields.
        4. Each strategy must be distinct in family or entry logic.
        5. Return a JSON array of exactly 3 strategy objects.

        OUTPUT FORMAT:
        Return ONLY a JSON array of strategy objects. Each object must match this schema:
        #{File.read(SCHEMA_PATH)}
      PROMPT
    end

    def self.mutation_prompt(features:, templates:)
      template = templates.sample || templates.first

      <<~PROMPT
        TASK: Mutate this existing strategy template to improve it for the current market conditions.

        TEMPLATE TO MUTATE:
        #{JSON.pretty_generate(template)}

        CURRENT MARKET FEATURES:
        #{JSON.pretty_generate(features)}
        #{entry_conditions_snippet_for_task_prompt}
        INSTRUCTIONS:
        1. Analyze how the current market features align with or diverge from this template's assumptions.
        2. Propose exactly 2 mutations:
           - Mutation A: Conservative — change 1-2 parameters or filter thresholds.
           - Mutation B: Aggressive — change entry conditions or exit logic while keeping the same family.
        3. Each mutation must have a different name and a rationale field explaining what changed and why.
        4. Keep parameter_ranges updated for all tunable values.
        5. If you change entry.conditions, every value must remain one of ALLOWED_ENTRY_CONDITION_IDS above (verbatim snake_case). Prefer reusing the template's condition ids when possible.

        OUTPUT FORMAT:
        Return ONLY a JSON array of exactly 2 strategy objects.
      PROMPT
    end

    def self.critique_prompt(features:, templates:)
      <<~PROMPT
        TASK: Critique these strategy candidates against the current market features.

        STRATEGIES TO CRITIQUE:
        #{JSON.pretty_generate(templates)}

        CURRENT MARKET FEATURES:
        #{JSON.pretty_generate(features)}

        INSTRUCTIONS:
        For each strategy, evaluate:
        1. Does the entry logic match observable patterns in the feature data?
        2. Is the stop placement realistic given current ATR?
        3. Are the targets achievable given session ranges and volatility?
        4. Are there missing filters that would prevent false signals?
        5. Are invalidation conditions comprehensive?

        OUTPUT FORMAT:
        Return ONLY a JSON array of objects with this structure:
        {
          "strategy_name": "string",
          "score": 0.0-1.0,
          "issues": ["string"],
          "improvements": ["string"],
          "viable": true/false
        }
      PROMPT
    end

    # Build a prompt for strategy documentation.
    def self.documentation_prompt(strategy:, backtest_results:)
      <<~PROMPT
        TASK: Write a strategy card document for this strategy based on its backtest results.

        STRATEGY:
        #{JSON.pretty_generate(strategy)}

        BACKTEST RESULTS:
        #{JSON.pretty_generate(backtest_results)}

        INSTRUCTIONS:
        Write a concise strategy card covering:
        1. What it trades and why it has edge
        2. Best sessions and instruments
        3. Required confirmations before entry
        4. Invalidation conditions
        5. Risk model summary
        6. Backtest performance summary
        7. Known failure modes
        8. Parameter tuning bounds

        OUTPUT FORMAT:
        Return ONLY a JSON object:
        {
          "title": "string",
          "summary": "string (2-3 sentences)",
          "edge_explanation": "string",
          "best_conditions": { "sessions": [], "instruments": [], "regimes": [] },
          "entry_checklist": ["string"],
          "invalidation_rules": ["string"],
          "risk_summary": "string",
          "performance_summary": { "expectancy": 0.0, "win_rate": 0.0, "profit_factor": 0.0, "max_drawdown": 0.0 },
          "failure_modes": ["string"],
          "tuning_notes": "string"
        }
      PROMPT
    end
  end
end
