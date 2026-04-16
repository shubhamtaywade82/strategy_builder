# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StrategyBuilder::CandleLoader do
  let(:market_data) { instance_double(CoinDCX::REST::Futures::MarketData) }
  let(:futures) { instance_double(CoinDCX::REST::Futures::Facade, market_data: market_data) }
  let(:client) { instance_double(CoinDCX::Client, futures: futures) }

  let(:loader) { described_class.new(client: client) }

  describe '#fetch' do
    it 'uses list_candlesticks with pair, from, to, and resolution' do
      from_ts = 1_700_000_000
      to_ts = from_ts + 3600
      row = {
        'time' => from_ts,
        'open' => '1',
        'high' => '2',
        'low' => '0.5',
        'close' => '1.5',
        'volume' => '100'
      }
      allow(market_data).to receive(:list_candlesticks).and_return([row])

      candles = loader.fetch(instrument: 'B-BTC_USDT', timeframe: '1m', from: from_ts, to: to_ts)

      expect(market_data).to have_received(:list_candlesticks).with(
        pair: 'B-BTC_USDT',
        from: be_a(Integer),
        to: be_a(Integer),
        resolution: '1'
      )
      expect(candles.size).to eq(1)
      expect(candles.first[:close]).to eq(1.5)
      expect(candles.first[:timeframe]).to eq('1m')
    end

    it 'unwraps candle rows from a Hash body with a data key' do
      from_ts = 1_700_000_000
      to_ts = from_ts + 60
      inner = { 'time' => from_ts, 'o' => '10', 'h' => '11', 'l' => '9', 'c' => '10.5', 'v' => '1' }
      allow(market_data).to receive(:list_candlesticks).and_return({ 'data' => [inner] })

      candles = loader.fetch(instrument: 'B-ETH_USDT', timeframe: '5m', from: from_ts, to: to_ts)

      expect(candles.size).to eq(1)
      expect(candles.first[:open]).to eq(10.0)
      expect(candles.first[:close]).to eq(10.5)
    end

    it 'converts millisecond Unix timestamps from the API to seconds' do
      ms = 1_774_000_000_000
      expected_seconds = 1_774_000_000
      row = {
        'time' => ms,
        'open' => '1',
        'high' => '2',
        'low' => '0.5',
        'close' => '1.5',
        'volume' => '100'
      }
      allow(market_data).to receive(:list_candlesticks).and_return([row])

      candles = loader.fetch(
        instrument: 'B-BTC_USDT',
        timeframe: '1m',
        from: expected_seconds,
        to: expected_seconds + 120
      )

      expect(candles.first[:timestamp]).to eq(expected_seconds)
    end

    it 'handles pagination correctly when API returns data in descending order' do
      from_ts = 1_700_000_000
      to_ts = from_ts + (2500 * 60) # 2500 minutes (2.5 requests of 1000)

      # 1st request: returns 1000 candles from from_ts to from_ts + 1000*60
      chunk1 = (0...1000).map do |i|
        { 'time' => from_ts + (i * 60), 'open' => '1', 'high' => '2', 'low' => '0.5', 'close' => '1.5',
          'volume' => '100' }
      end.reverse

      # 2nd request: returns 1000 candles from from_ts + 1000*60 to from_ts + 2000*60
      chunk2 = (1000...2000).map do |i|
        { 'time' => from_ts + (i * 60), 'open' => '1', 'high' => '2', 'low' => '0.5', 'close' => '1.5',
          'volume' => '100' }
      end.reverse

      # 3rd request: returns 500 candles from from_ts + 2000*60 to to_ts
      chunk3 = (2000...2500).map do |i|
        { 'time' => from_ts + (i * 60), 'open' => '1', 'high' => '2', 'low' => '0.5', 'close' => '1.5',
          'volume' => '100' }
      end.reverse

      allow(market_data).to receive(:list_candlesticks).and_return(chunk1, chunk2, chunk3)

      candles = loader.fetch(
        instrument: 'B-BTC_USDT',
        timeframe: '1m',
        from: from_ts,
        to: to_ts
      )

      expect(market_data).to have_received(:list_candlesticks).exactly(3).times
      expect(candles.size).to eq(2500)

      # Assert the overall array is strictly ascending
      timestamps = candles.map { |c| c[:timestamp] }
      expect(timestamps).to eq(timestamps.sort)
    end

    it 'handles gaps in data by advancing cursor correctly' do
      from_ts = 1_700_000_000
      to_ts = from_ts + (3000 * 60) # 3 chunks of 1000

      # 1st request: returns 10 candles (big gap at the end)
      chunk1 = (0...10).map do |i|
        { 'time' => from_ts + (i * 60), 'open' => '1', 'high' => '2', 'low' => '0.5', 'close' => '1.5',
          'volume' => '100' }
      end.reverse

      # 2nd request: completely empty
      chunk2 = []

      # 3rd request: returns 10 candles near the end
      chunk3 = (2990...3000).map do |i|
        { 'time' => from_ts + (i * 60), 'open' => '1', 'high' => '2', 'low' => '0.5', 'close' => '1.5',
          'volume' => '100' }
      end.reverse

      allow(market_data).to receive(:list_candlesticks).and_return(chunk1, chunk2, chunk3)

      candles = loader.fetch(
        instrument: 'B-BTC_USDT',
        timeframe: '1m',
        from: from_ts,
        to: to_ts
      )

      expect(market_data).to have_received(:list_candlesticks).exactly(3).times
      expect(candles.size).to eq(20)
      timestamps = candles.map { |c| c[:timestamp] }
      expect(timestamps).to eq(timestamps.sort)
    end
  end
end
