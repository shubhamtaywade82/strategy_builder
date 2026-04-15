# frozen_string_literal: true

module StrategyBuilder
  class InstrumentLoader
    def initialize(client: StrategyBuilder.coindcx_client)
      @client = client
      @logger = StrategyBuilder.logger
      @cache = {}
      @cache_ttl = 300 # 5 minutes
      @cache_at = {}
    end

    def active_instruments(margin_currency: "USDT")
      cache_key = "active_#{margin_currency}"
      return @cache[cache_key] if fresh?(cache_key)

      raw = @client.futures.market_data.list_active_instruments(
        margin_currency_short_names: [margin_currency]
      )

      instruments = raw.map { |i| normalize_instrument(i) }
      cache!(cache_key, instruments)
      instruments
    end

    def instrument_details(pair:, margin_currency: "USDT")
      cache_key = "detail_#{pair}_#{margin_currency}"
      return @cache[cache_key] if fresh?(cache_key)

      raw = @client.futures.market_data.fetch_instrument(
        pair: pair,
        margin_currency_short_name: margin_currency
      )

      detail = normalize_instrument(raw)
      cache!(cache_key, detail)
      detail
    end

    def stats(pair:)
      cache_key = "stats_#{pair}"
      return @cache[cache_key] if fresh?(cache_key)

      raw = @client.futures.market_data.stats(pair: pair)
      cache!(cache_key, raw)
      raw
    end

    def tradeable_pairs(margin_currency: "USDT", min_volume_usdt: 100_000)
      active_instruments(margin_currency: margin_currency)
        .select { |i| i[:status] == "active" || i[:status] == "operational" }
        .select { |i| i[:volume_24h].to_f >= min_volume_usdt }
        .map { |i| i[:pair] }
    end

    private

    def normalize_instrument(raw)
      {
        pair:                raw["symbol"] || raw["pair"] || raw[:symbol] || raw[:pair],
        base_currency:       raw["base_currency"] || raw[:base_currency],
        quote_currency:      raw["quote_currency"] || raw[:quote_currency],
        margin_currency:     raw["margin_currency_short_name"] || raw[:margin_currency_short_name],
        tick_size:           raw["tick_size"]&.to_f || raw[:tick_size]&.to_f,
        lot_size:            raw["lot_size"]&.to_f || raw[:lot_size]&.to_f,
        min_quantity:        raw["min_quantity"]&.to_f || raw[:min_quantity]&.to_f,
        max_leverage:        raw["max_leverage"]&.to_i || raw[:max_leverage]&.to_i,
        maker_fee:           raw["maker_commission_rate"]&.to_f || raw[:maker_commission_rate]&.to_f,
        taker_fee:           raw["taker_commission_rate"]&.to_f || raw[:taker_commission_rate]&.to_f,
        status:              raw["state"] || raw["status"] || raw[:state] || raw[:status],
        volume_24h:          raw["turnover_usd"] || raw["volume_24h"] || raw[:turnover_usd],
        contract_type:       raw["contract_type"] || raw[:contract_type]
      }
    end

    def fresh?(key)
      @cache.key?(key) && @cache_at[key] && (Time.now.to_i - @cache_at[key]) < @cache_ttl
    end

    def cache!(key, value)
      @cache[key] = value
      @cache_at[key] = Time.now.to_i
    end
  end
end
