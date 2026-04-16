# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::StrategyCatalog do
  let(:tmpdir) { Dir.mktmpdir }
  let(:storage) { File.join(tmpdir, "strategies") }

  after do
    FileUtils.remove_entry(tmpdir)
  end

  describe "#write_pipeline_run_summary" do
    it "writes PIPELINE_RUN.md with a row per catalog entry" do
      StrategyBuilder.configure { |c| c.output_dir = tmpdir }

      cat = described_class.new(storage_dir: storage)
      cat.add(
        { name: "Alpha", family: "session_breakout", timeframes: %w[5m], entry: { conditions: %w[a] },
          exit: { targets: [1.0], partial_exits: [1.0] }, risk: { stop: "x", position_sizing: "fixed_risk_percent" } },
        status: "reject"
      )
      id = cat.all.first[:id]
      cat.attach_backtest(
        id,
        { instrument: "B-BTC_USDT", metrics: { expectancy: 0.01, trade_count: 5 }, walk_forward: { passes_walk_forward: false } }
      )
      cat.attach_ranking(id, { final_score: 0.42, status: "reject" })

      path = cat.write_pipeline_run_summary(query: "test query")

      expect(path).to eq(File.join(tmpdir, "reports", "PIPELINE_RUN.md"))
      body = File.read(path)
      expect(body).to include("test query")
      expect(body).to include("Alpha")
      expect(body).to include("session_breakout")
      expect(body).to include("**reject**")
      expect(body).to include("`#{id}`")
    end
  end
end
