# frozen_string_literal: true

module StrategyBuilder
  class CandleLoader
    TIMEFRAME_SECONDS = {
      "1m" => 60, "3m" => 180, "5m" => 300, "15m" => 900,
      "30m" => 1800, "1h" => 3600, "2h" => 7200, "4h" => 14_400,
      "6h" => 21_600, "1d" => 86_400, "1w" => 604_800
    }.freeze

    # CoinDCX candle endpoint resolution mapping
    RESOLUTION_MAP = {
      "1m" => "1", "3m" => "3", "5m" => "5", "15m" => "15",
      "30m" => "30", "1h" => "60", "2h" => "120", "4h" => "240",
      "6h" => "360", "1d" => "1D", "1w" => "1W"
    }.freeze

    MAX_CANDLES_PER_REQUEST = 500

    def initialize(client: StrategyBuilder.coindcx_client)
      @client = client
      @logger = StrategyBuilder.logger
    end

    # Fetch candles for an instrument across a date range.
    # Returns Array<Hash> with keys: :timestamp, :open, :high, :low, :close, :volume
    def fetch(instrument:, timeframe:, from:, to: Time.now)
      resolution = RESOLUTION_MAP.fetch(timeframe) do
        raise DataError, "Unknown timeframe: #{timeframe}"
      end

      from_ts = from.is_a?(Time) ? from.to_i : from
      to_ts = to.is_a?(Time) ? to.to_i : to

      all_candles = []
      cursor = from_ts

      loop do
        break if cursor >= to_ts

        @logger.debug { "Fetching #{instrument} #{timeframe} from #{Time.at(cursor)}" }

        raw = fetch_batch(
          instrument: instrument,
          resolution: resolution,
          from: cursor,
          to: [cursor + (MAX_CANDLES_PER_REQUEST * TIMEFRAME_SECONDS.fetch(timeframe)), to_ts].min
        )

        break if raw.nil? || raw.empty?

        normalized = raw.map { |c| normalize_candle(c, timeframe) }
        all_candles.concat(normalized)

        last_ts = normalized.last[:timestamp]
        break if last_ts <= cursor # no progress

        cursor = last_ts + TIMEFRAME_SECONDS.fetch(timeframe)
      end

      deduplicate(all_candles).sort_by { |c| c[:timestamp] }
    end

    # Fetch candles for multiple timeframes in parallel-ready structure
    def fetch_mtf(instrument:, timeframes:, from:, to: Time.now)
      timeframes.each_with_object({}) do |tf, result|
        result[tf] = fetch(instrument: instrument, timeframe: tf, from: from, to: to)
        @logger.info { "Loaded #{result[tf].size} candles for #{instrument} #{tf}" }
      end
    end

    private

    def fetch_batch(instrument:, resolution:, from:, to:)
      # CoinDCX futures candle endpoint
      # GET /market_data/candles?pair=B-BTC_USDT&interval=5&start_time=...&end_time=...
      @client.futures.market_data.candles(
        pair: instrument,
        interval: resolution,
        start_time: from,
        end_time: to
      )
    rescue CoinDCX::Errors::RateLimitError => e
      @logger.warn { "Rate limited, backing off: #{e.message}" }
      sleep(e.respond_to?(:retry_after) ? e.retry_after : 2)
      retry
    rescue CoinDCX::Errors::TransportError => e
      @logger.error { "Transport error fetching candles: #{e.message}" }
      nil
    end

    def normalize_candle(raw, timeframe)
      {
        timestamp: raw["time"] || raw["t"] || raw[:time] || raw[:t],
        open:      (raw["open"] || raw["o"] || raw[:open] || raw[:o]).to_f,
        high:      (raw["high"] || raw["h"] || raw[:high] || raw[:h]).to_f,
        low:       (raw["low"]  || raw["l"] || raw[:low]  || raw[:l]).to_f,
        close:     (raw["close"]|| raw["c"] || raw[:close]|| raw[:c]).to_f,
        volume:    (raw["volume"] || raw["v"] || raw[:volume] || raw[:v]).to_f,
        timeframe: timeframe
      }
    end

    def deduplicate(candles)
      candles.uniq { |c| c[:timestamp] }
    end
  end
end
