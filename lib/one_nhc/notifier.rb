# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module OneNHC
  # Sends controller decisions to a command, a webhook and/or email.
  class Notifier
    def initialize(config)
      notify   = config.dig("controller", "notify") || {}
      @command = notify["command"].to_s
      @webhook = notify["webhook"].to_s
      @email   = build_email(notify["email"])
    end

    def notify(message, host:, decision:)
      payload = self.class.payload(message, host, decision)

      run_command(payload) unless @command.empty?
      post_webhook(payload) unless @webhook.empty?
      deliver_email(payload)
    end

    # Payload shared by every notification channel.
    def self.payload(message, host, decision, now: Time.now)
      {
        message: message,
        host: host.name,
        host_id: host.id,
        status: host.status,
        action: decision.action.to_s,
        applied: decision.applied,
        time: now.utc.iso8601,
        sample: host.respond_to?(:sample) ? host.sample : nil,
        details: host.respond_to?(:details) ? (host.details || {}) : {}
      }
    end

    private

    def build_email(config)
      return nil unless config

      OneNHC::EmailNotifier.new(config)
    rescue StandardError => e
      warn "one-nhc: email notifications disabled: #{e.class}: #{e.message}"
      nil
    end

    def run_command(payload)
      env = {
        "NHC_MESSAGE" => payload[:message].to_s,
        "NHC_HOST" => payload[:host].to_s,
        "NHC_HOST_ID" => payload[:host_id].to_s,
        "NHC_STATUS" => payload[:status].to_s,
        "NHC_ACTION" => payload[:action].to_s,
        "NHC_APPLIED" => payload[:applied].to_s
      }

      _out, err, status, result = Shell.capture(["sh", "-c", @command], timeout: 10, env: env)
      return if result == :ok && status&.success?

      warn "one-nhc: notify command failed (#{result}): #{err.to_s.strip[0, 200]}"
    rescue StandardError => e
      warn "one-nhc: notify command failed: #{e.message}"
    end

    def post_webhook(payload)
      uri  = URI.parse(@webhook)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)

      response = http.request(request)
      return if response.is_a?(Net::HTTPSuccess)

      warn "one-nhc: webhook returned HTTP #{response.code}"
    rescue StandardError => e
      warn "one-nhc: webhook failed: #{e.message}"
    end

    def deliver_email(payload)
      @email&.deliver(payload)
    rescue StandardError => e
      warn "one-nhc: email notification failed: #{e.class}: #{e.message}"
    end
  end
end
