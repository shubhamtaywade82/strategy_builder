# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrategyBuilder::CandleLoader do
  let(:market_data) { instance_double(CoinDCX::REST::Futures::MarketData) }
  let(:futures) { instance_double(CoinDCX::REST::Futures::Facade, market_data: market_data) }
  let(:client) { instance_double(CoinDCX::Client, futures: futures) }

  let(:loader) { described_class.new(client: client) }

  describe "#fetch" do
    it "uses list_candlesticks with pair, from, to, and resolution" do
      from_ts = 1_700_000_000
      to_ts = from_ts + 3600
      row = {
        "time" => from_ts,
        "open" => "1",
        "high" => "2",
        "low" => "0.5",
        "close" => "1.5",
        "volume" => "100"
      }
      allow(market_data).to receive(:list_candlesticks).and_return([row])

      candles = loader.fetch(instrument: "B-BTC_USDT", timeframe: "1m", from: from_ts, to: to_ts)

      expect(market_data).to have_received(:list_candlesticks).with(
        pair: "B-BTC_USDT",
        from: be_a(Integer),
        to: be_a(Integer),
        resolution: "1"
      )
      expect(candles.size).to eq(1)
      expect(candles.first[:close]).to eq(1.5)
      expect(candles.first[:timeframe]).to eq("1m")
    end

    it "unwraps candle rows from a Hash body with a data key" do
      from_ts = 1_700_000_000
      to_ts = from_ts + 60
      inner = { "time" => from_ts, "o" => "10", "h" => "11", "l" => "9", "c" => "10.5", "v" => "1" }
      allow(market_data).to receive(:list_candlesticks).and_return({ "data" => [inner] })

      candles = loader.fetch(instrument: "B-ETH_USDT", timeframe: "5m", from: from_ts, to: to_ts)

      expect(candles.size).to eq(1)
      expect(candles.first[:open]).to eq(10.0)
      expect(candles.first[:close]).to eq(10.5)
    end
  end
end
