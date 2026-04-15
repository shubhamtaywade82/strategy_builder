# frozen_string_literal: true

module StrategyBuilder
  # Guards allowed backtest position states (only :position_open is active in this engine).
  module BacktestPositionState
    ACTIVE = :position_open

    module_function

    def active?(position)
      position&.state == ACTIVE
    end

    def ensure_active_for_exits!(position)
      return if active?(position)

      raise BacktestError, "Expected position.state == :position_open for exit handling, got #{position&.state.inspect}"
    end
  end
end
