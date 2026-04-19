# frozen_string_literal: true

module StrategyBuilder
  module Agent
    # Orchestrates the 4 desk roles: Observer → PatternAnalyst → TradeDesigner → Skeptic.
    # Replaces the single StrategyGenerator LLM call in the propose phase.
    class DeskPipeline
      def initialize(client: StrategyBuilder.ollama_client)
        @observer        = Roles::Observer.new(client: client)
        @pattern_analyst = Roles::PatternAnalyst.new(client: client)
        @trade_designer  = Roles::TradeDesigner.new(client: client)
        @skeptic         = Roles::Skeptic.new(client: client)
        @logger          = StrategyBuilder.logger
      end

      # @param instrument [String]
      # @param features [Hash] from FeatureBuilder.build
      # @return [Array<Hash>] skeptic-approved strategy candidates
      def run(instrument:, features:)
        snapshot = State::SnapshotBuilder.build(instrument: instrument, features: features)
        @logger.info { "DeskPipeline: #{instrument} — regime=#{snapshot.regime} bias=#{snapshot.bias} session=#{snapshot.session}" }

        observer_result = @observer.classify(snapshot)
        @logger.info { "Observer: #{observer_result[:narrative].to_s.slice(0, 120)}" }

        mined = Patterns::PatternMiner.mine(snapshot)
        @logger.info { "PatternMiner: #{mined.size} candidates (#{mined.map { |p| p[:name] }.join(', ')})" }

        confirmed = @pattern_analyst.analyze(
          market_state:    snapshot,
          mined_patterns:  mined,
          observer_result: observer_result
        )
        @logger.info { "PatternAnalyst: #{confirmed.size} confirmed patterns" }

        candidates = @trade_designer.synthesize(
          market_state:       snapshot,
          confirmed_patterns: confirmed,
          observer_result:    observer_result
        )
        @logger.info { "TradeDesigner: #{candidates.size} candidates generated" }

        accepted = candidates.filter_map { |c| @skeptic.review(c, snapshot) }
        @logger.info { "Skeptic: #{accepted.size}/#{candidates.size} accepted" }

        accepted
      end
    end
  end
end
