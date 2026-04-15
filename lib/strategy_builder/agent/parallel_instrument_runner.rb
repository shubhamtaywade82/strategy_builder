# frozen_string_literal: true

require "concurrent"

module StrategyBuilder
  module Agent
    # Bounded parallel execution for per-instrument HTTP (discover / validate).
    module ParallelInstrumentRunner
      module_function

      def map_parallel(items, max_parallel:, &block)
        return items.map(&block) if items.empty?
        return items.map(&block) if max_parallel <= 1

        max = [max_parallel, items.size].min
        pool = Concurrent::FixedThreadPool.new(max)
        begin
          futures = items.map do |item|
            Concurrent::Promises.future_on(pool) { block.call(item) }
          end
          futures.map(&:value!)
        ensure
          pool.shutdown
          unless pool.wait_for_termination(120)
            StrategyBuilder.logger.warn { "Thread pool did not terminate cleanly within 120s" }
          end
        end
      end
    end
  end
end
