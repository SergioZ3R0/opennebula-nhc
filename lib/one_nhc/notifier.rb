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
    # HTTP statuses that are worth retrying even though they are client errors.
    RETRYABLE_STATUS = [408, 429].freeze
    MAX_RETRY_AFTER  = 30

    def initialize(config, clock: nil, sleeper: nil)
      notify   = config.dig("controller", "notify") || {}
      @enabled = notify.fetch("enabled", true) != false
      @command = notify["command"].to_s
      @webhook = notify["webhook"].to_s

      @webhook_retries      = (notify["webhook_retries"] || 2).to_i
      @webhook_retry_delay  = (notify["webhook_retry_delay"] || 1).to_f
      @webhook_min_interval = (notify["webhook_min_interval"] || 0.2).to_f

      @clock            = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper          = sleeper || ->(seconds) { sleep(seconds) }
      @last_webhook_at  = nil
      @email            = build_email(notify["email"])
    end

    def notify(message, host:, decision:)
      return false unless @enabled

      payload = self.class.payload(message, host, decision)

      run_command(payload) unless @command.empty?
      post_webhook(payload) unless @webhook.empty?
      deliver_email(payload)
      true
    end

    # Payload shared by every notification channel.
    def self.payload(message, host, decision, now: Time.now)
      Payload.build(message, host, decision, now: now)
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
      attempts = @webhook_retries + 1
      attempt  = 0

      loop do
        attempt += 1
        throttle_webhook

        ok, retryable, reason, retry_after = deliver_webhook(payload)
        return if ok

        if !retryable || attempt >= attempts
          warn "one-nhc: webhook failed after #{attempt} attempt(s): #{reason}"
          return
        end

        delay = retry_after || webhook_backoff(attempt)
        warn format(
          "one-nhc: webhook attempt %d failed (%s), retrying in %.1fs",
          attempt, reason, delay
        )
        @sleeper.call(delay) if delay.positive?
      end
    end

    # Returns [ok, retryable, reason, retry_after_seconds].
    def deliver_webhook(payload)
      uri  = URI.parse(@webhook)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)

      response = http.request(request)
      return [true, false, nil, nil] if response.is_a?(Net::HTTPSuccess)

      code      = response.code.to_i
      retryable = response.is_a?(Net::HTTPServerError) ||
                  RETRYABLE_STATUS.include?(code)
      retry_after = retry_after_seconds(response) if code == 429

      [false, retryable, "HTTP #{response.code}", retry_after]
    rescue StandardError => e
      [false, true, "#{e.class}: #{e.message}", nil]
    end

    # Respect Retry-After on 429, but never sleep for an unbounded time.
    def retry_after_seconds(response)
      value = response["Retry-After"].to_s
      return nil unless value.match?(/\A\d+(\.\d+)?\z/)

      [value.to_f, MAX_RETRY_AFTER].min
    end

    def webhook_backoff(attempt)
      @webhook_retry_delay * (2**(attempt - 1))
    end

    # Rate limit by minimum interval between POST starts. It applies within one
    # controller run, which is where many hosts can fail at once.
    def throttle_webhook
      return if @webhook_min_interval <= 0

      now = @clock.call
      if @last_webhook_at
        wait = @webhook_min_interval - (now - @last_webhook_at)
        @sleeper.call(wait) if wait.positive?
      end

      @last_webhook_at = @clock.call
    end

    def deliver_email(payload)
      @email&.deliver(payload)
    rescue StandardError => e
      warn "one-nhc: email notification failed: #{e.class}: #{e.message}"
    end
  end
end
