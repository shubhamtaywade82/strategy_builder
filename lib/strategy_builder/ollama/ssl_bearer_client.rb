# frozen_string_literal: true

module StrategyBuilder
  # ollama-client 0.2.x uses Net::HTTP.start without +use_ssl: true+, so HTTPS hosts
  # (Ollama Cloud at https://ollama.com) fail. This subclass adds TLS + optional Bearer auth.
  #
  # Behavior otherwise matches Ollama::Client (ollama-client 0.2.7 private HTTP paths).
  class OllamaSslBearerClient < Ollama::Client
    def initialize(config:, bearer_token: nil)
      super(config: config)
      @bearer_token = bearer_token&.to_s&.strip
    end

    def health(return_meta: false)
      ping_uri = URI.join(@base_uri.to_s.end_with?("/") ? @base_uri.to_s : "#{@base_uri}/", "api/ping")
      started_at = monotonic_time

      req = Net::HTTP::Get.new(ping_uri)
      authorize_request!(req)
      res = http_start(ping_uri) { |http| http.request(req) }

      ok = res.is_a?(Net::HTTPSuccess)
      return ok unless return_meta

      {
        "ok" => ok,
        "meta" => {
          "endpoint" => "/api/ping",
          "status_code" => res.code.to_i,
          "latency_ms" => elapsed_ms(started_at)
        }
      }
    rescue Net::ReadTimeout, Net::OpenTimeout
      return false unless return_meta

      {
        "ok" => false,
        "meta" => {
          "endpoint" => "/api/ping",
          "error" => "timeout",
          "latency_ms" => elapsed_ms(started_at)
        }
      }
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      return false unless return_meta

      {
        "ok" => false,
        "meta" => {
          "endpoint" => "/api/ping",
          "error" => e.message,
          "latency_ms" => elapsed_ms(started_at)
        }
      }
    end

    def list_models
      tags_uri = URI("#{@config.base_url}/api/tags")
      req = Net::HTTP::Get.new(tags_uri)
      authorize_request!(req)

      res = http_start(tags_uri) { |http| http.request(req) }

      raise Ollama::Error, "Failed to fetch models: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      body = JSON.parse(res.body)
      body["models"]&.map { |m| m["name"] } || []
    rescue JSON::ParserError => e
      raise Ollama::InvalidJSONError, "Failed to parse models response: #{e.message}"
    rescue Net::ReadTimeout, Net::OpenTimeout
      raise Ollama::TimeoutError, "Request timed out after #{@config.timeout}s"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise Ollama::Error, "Connection failed: #{e.message}"
    end

    private

    def authorize_request!(req)
      return if @bearer_token.nil? || @bearer_token.empty?

      req["Authorization"] = "Bearer #{@bearer_token}"
    end

    def http_start(uri, &block)
      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        read_timeout: @config.timeout,
        open_timeout: @config.timeout,
        &block
      )
    end

    def call_api(prompt, model: nil)
      req = Net::HTTP::Post.new(@uri)
      req["Content-Type"] = "application/json"
      authorize_request!(req)

      body = {
        model: model || @config.model,
        prompt: prompt,
        stream: false,
        temperature: @config.temperature,
        top_p: @config.top_p,
        num_ctx: @config.num_ctx
      }

      if @current_schema
        body[:format] = @current_schema
        body[:prompt] = enhance_prompt_for_json(prompt)
      end

      req.body = body.to_json

      res = http_start(@uri) { |http| http.request(req) }

      handle_http_error(res, requested_model: model || @config.model) unless res.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(res.body)
      parsed["response"]
    rescue JSON::ParserError => e
      raise Ollama::InvalidJSONError, "Failed to parse API response: #{e.message}"
    rescue Net::ReadTimeout, Net::OpenTimeout
      raise Ollama::TimeoutError, "Request timed out after #{@config.timeout}s"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise Ollama::Error, "Connection failed: #{e.message}"
    end

    def call_chat_api(model:, messages:, format:, tools:, options:)
      req = Net::HTTP::Post.new(@chat_uri)
      req["Content-Type"] = "application/json"
      authorize_request!(req)

      body = {
        model: model || @config.model,
        messages: messages,
        stream: false
      }

      body_options = {
        temperature: options[:temperature] || @config.temperature,
        top_p: options[:top_p] || @config.top_p,
        num_ctx: options[:num_ctx] || @config.num_ctx
      }
      body[:options] = body_options

      body[:format] = format if format
      body[:tools] = tools if tools

      req.body = body.to_json

      res = http_start(@chat_uri) { |http| http.request(req) }

      handle_http_error(res, requested_model: model || @config.model) unless res.is_a?(Net::HTTPSuccess)

      response_body = JSON.parse(res.body)
      response_body["message"]["content"]
    rescue JSON::ParserError => e
      raise Ollama::InvalidJSONError, "Failed to parse API response: #{e.message}"
    rescue Net::ReadTimeout, Net::OpenTimeout
      raise Ollama::TimeoutError, "Request timed out after #{@config.timeout}s"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise Ollama::Error, "Connection failed: #{e.message}"
    end

    def call_chat_api_raw(model:, messages:, format:, tools:, options:)
      req = Net::HTTP::Post.new(@chat_uri)
      req["Content-Type"] = "application/json"
      authorize_request!(req)

      body = {
        model: model || @config.model,
        messages: messages,
        stream: false
      }

      body_options = {
        temperature: options[:temperature] || @config.temperature,
        top_p: options[:top_p] || @config.top_p,
        num_ctx: options[:num_ctx] || @config.num_ctx
      }
      body[:options] = body_options

      body[:format] = format if format
      body[:tools] = tools if tools

      req.body = body.to_json

      res = http_start(@chat_uri) { |http| http.request(req) }

      handle_http_error(res, requested_model: model || @config.model) unless res.is_a?(Net::HTTPSuccess)

      res.body
    rescue Net::ReadTimeout, Net::OpenTimeout
      raise Ollama::TimeoutError, "Request timed out after #{@config.timeout}s"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise Ollama::Error, "Connection failed: #{e.message}"
    end

    def call_chat_api_raw_stream(model:, messages:, format:, tools:, options:)
      req = Net::HTTP::Post.new(@chat_uri)
      req["Content-Type"] = "application/json"
      authorize_request!(req)

      body = {
        model: model || @config.model,
        messages: messages,
        stream: true
      }

      body_options = {
        temperature: options[:temperature] || @config.temperature,
        top_p: options[:top_p] || @config.top_p,
        num_ctx: options[:num_ctx] || @config.num_ctx
      }
      body[:options] = body_options

      body[:format] = format if format
      body[:tools] = tools if tools

      req.body = body.to_json

      final_obj = nil
      aggregated = {
        "message" => {
          "role" => "assistant",
          "content" => +""
        }
      }

      buffer = +""

      http_start(@chat_uri) do |http|
        http.request(req) do |res|
          handle_http_error(res, requested_model: model || @config.model) unless res.is_a?(Net::HTTPSuccess)

          res.read_body do |chunk|
            buffer << chunk

            while (newline_idx = buffer.index("\n"))
              line = buffer.slice!(0, newline_idx + 1).strip
              next if line.empty?

              if line.start_with?("data:")
                line = line.sub(/\Adata:\s*/, "").strip
              elsif line.start_with?("event:") || line.start_with?(":")
                next
              end

              next if line.empty? || line == "[DONE]"

              obj = JSON.parse(line)

              yield(obj) if block_given?

              msg = obj["message"]
              if msg.is_a?(Hash)
                delta_content = msg["content"]
                aggregated["message"]["content"] << delta_content.to_s if delta_content

                aggregated["message"]["tool_calls"] = msg["tool_calls"] if msg["tool_calls"]

                aggregated["message"]["role"] = msg["role"] if msg["role"]
              end

              final_obj = obj if obj["done"] == true
            end
          end
        end
      end

      if final_obj.is_a?(Hash)
        combined = final_obj.dup
        combined_message =
          if combined["message"].is_a?(Hash)
            combined["message"].dup
          else
            {}
          end

        agg_message = aggregated["message"] || {}

        agg_content = agg_message["content"].to_s
        combined_message["content"] = agg_content unless agg_content.empty?

        combined_message["tool_calls"] = agg_message["tool_calls"] if agg_message.key?("tool_calls")
        combined_message["role"] ||= agg_message["role"] if agg_message["role"]

        combined["message"] = combined_message unless combined_message.empty?
        return combined
      end

      aggregated
    rescue JSON::ParserError => e
      raise Ollama::InvalidJSONError, "Failed to parse streaming response: #{e.message}"
    rescue Net::ReadTimeout, Net::OpenTimeout
      raise Ollama::TimeoutError, "Request timed out after #{@config.timeout}s"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise Ollama::Error, "Connection failed: #{e.message}"
    end
  end
end
