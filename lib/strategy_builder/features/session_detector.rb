# frozen_string_literal: true

module StrategyBuilder
  class SessionDetector
    # Session windows in UTC.
    # Crypto trades 24/7 but institutional activity clusters in these windows.
    SESSIONS = {
      "asia"           => { start_hour: 0,  end_hour: 8  },
      "london"         => { start_hour: 7,  end_hour: 16 },
      "new_york"       => { start_hour: 13, end_hour: 22 },
      "asia_london"    => { start_hour: 7,  end_hour: 8  }, # overlap
      "london_ny"      => { start_hour: 13, end_hour: 16 }, # overlap
      "off_hours"      => { start_hour: 22, end_hour: 0  }
    }.freeze

    # Tag each candle with its session(s).
    # Returns Array<Hash> with :sessions key added.
    def self.tag_candles(candles)
      candles.map do |candle|
        ts = candle[:timestamp].is_a?(Time) ? candle[:timestamp] : Time.at(candle[:timestamp]).utc
        hour = ts.hour

        sessions = SESSIONS.select do |_name, window|
          if window[:start_hour] < window[:end_hour]
            hour >= window[:start_hour] && hour < window[:end_hour]
          else
            hour >= window[:start_hour] || hour < window[:end_hour]
          end
        end.keys

        candle.merge(sessions: sessions)
      end
    end

    # Detect which sessions are present in the candle set.
    def self.detect_sessions(candles)
      return [] if candles.nil? || candles.empty?

      tagged = tag_candles(candles)
      tagged.flat_map { |c| c[:sessions] }.uniq.sort
    end

    # Group candles by session for per-session analysis.
    def self.group_by_session(candles)
      tagged = tag_candles(candles)
      SESSIONS.keys.each_with_object({}) do |session, result|
        result[session] = tagged.select { |c| c[:sessions].include?(session) }
      end
    end

    # Compute session range (high/low) for a given session on a given day.
    def self.session_range(candles, session:, date:)
      tagged = tag_candles(candles)
      day_start = Time.utc(date.year, date.month, date.day)
      day_end = day_start + 86_400

      session_candles = tagged.select do |c|
        ts = c[:timestamp].is_a?(Time) ? c[:timestamp].to_i : c[:timestamp]
        ts >= day_start.to_i && ts < day_end.to_i && c[:sessions].include?(session)
      end

      return nil if session_candles.empty?

      {
        session: session,
        date: date,
        high: session_candles.map { |c| c[:high] }.max,
        low: session_candles.map { |c| c[:low] }.min,
        open: session_candles.first[:open],
        close: session_candles.last[:close],
        volume: session_candles.sum { |c| c[:volume] },
        candle_count: session_candles.size
      }
    end

    # UTC calendar day [start_i, end_i) for the day containing +reference_candle+.
    def self.utc_day_bounds(reference_candle)
      ts = reference_candle[:timestamp]
      t = ts.is_a?(Time) ? ts.utc : Time.at(ts).utc
      day_start = Time.utc(t.year, t.month, t.day)
      [day_start.to_i, day_start.to_i + 86_400]
    end

    # Candles tagged +session+ on the same UTC date as +reference_candle+, drawn only from +candles+.
    def self.candles_for_session_on_day(candles, session:, reference_candle:)
      return [] if candles.nil? || candles.empty?

      day_start_i, day_end_i = utc_day_bounds(reference_candle)
      tagged = tag_candles(candles)
      tagged.select do |c|
        ts = c[:timestamp].is_a?(Time) ? c[:timestamp].to_i : c[:timestamp]
        ts >= day_start_i && ts < day_end_i && c[:sessions].include?(session)
      end
    end

    # Asia session high/low for the UTC day of +reference_candle+, using only history in +candles+ (prefix-safe).
    # Returns { high:, low:, candle_count: } or nil when the range is not yet meaningful.
    def self.asia_session_box(candles, reference_candle, min_candles: 3, min_range_atr_fraction: 0.02)
      return nil if candles.nil? || candles.empty? || reference_candle.nil?

      asia = candles_for_session_on_day(candles, session: "asia", reference_candle: reference_candle)
      return nil if asia.size < min_candles

      high = asia.map { |c| c[:high] }.max
      low = asia.map { |c| c[:low] }.min
      range = high - low
      return nil if range <= 1e-12

      atr = VolatilityProfile.atr(candles).compact.last
      atr ||= range
      return nil if range < atr * min_range_atr_fraction

      { high: high, low: low, candle_count: asia.size }
    end
  end
end
