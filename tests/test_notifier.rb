# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class TestNotifier < Minitest::Test
  class FakeEmail
    attr_reader :payloads

    def initialize(raise_error: false)
      @payloads   = []
      @raise_error = raise_error
    end

    def deliver(payload)
      raise "email boom" if @raise_error

      @payloads << payload
      true
    end
  end

  # Minimal Net::HTTP double. The block receives the attempt number.
  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout
    attr_reader :requests

    def initialize(&block)
      @block    = block
      @requests = 0
    end

    def request(_request)
      @requests += 1
      @block.call(@requests)
    end
  end

  class FakeClock
    attr_reader :value

    def initialize
      @value = 0.0
    end

    def call
      @value
    end

    def advance(seconds)
      @value += seconds
    end
  end

  def ok_response
    Net::HTTPOK.new("1.1", "200", "OK")
  end

  def error_response(klass, code)
    klass.new("1.1", code.to_s, "error")
  end

  def host
    OneNHC::HostView.new(
      id: 1,
      name: "node01",
      status: "CRIT",
      state: OneNHC::Controller::HOST_MONITORED,
      sample: 123,
      details: { "NHC_STATUS" => "CRIT" }
    )
  end

  def decision
    OneNHC::Controller::Decision.new(
      host: host, action: :disable, reason: "test", applied: true
    )
  end

  def config
    OneNHC::Config.new(
      "groups" => {},
      "checks" => {},
      "controller" => OneNHC::Config::DEFAULTS["controller"].merge(
        "notify" => { "email" => { "to" => "ops@example.com" } }
      )
    )
  end

  def test_payload_includes_host_details
    payload = OneNHC::Notifier.payload(
      "msg", host, decision, now: Time.utc(2026, 1, 1)
    )

    assert_equal "msg", payload[:message]
    assert_equal "node01", payload[:host]
    assert_equal 1, payload[:host_id]
    assert_equal "CRIT", payload[:status]
    assert_equal "disable", payload[:action]
    assert_equal true, payload[:applied]
    assert_equal "2026-01-01T00:00:00Z", payload[:time]
    assert_equal 123, payload[:sample]
    assert_equal({ "NHC_STATUS" => "CRIT" }, payload[:details])
  end

  def test_email_channel_receives_the_payload
    fake = FakeEmail.new

    with_stub(OneNHC::EmailNotifier, :new, fake) do
      OneNHC::Notifier.new(config).notify("msg", host: host, decision: decision)
    end

    assert_equal 1, fake.payloads.size
    assert_equal "node01", fake.payloads.first[:host]
    assert_equal "CRIT", fake.payloads.first[:status]
  end

  def test_email_failure_does_not_raise
    fake = FakeEmail.new(raise_error: true)
    old_stderr = $stderr
    $stderr = StringIO.new

    begin
      with_stub(OneNHC::EmailNotifier, :new, fake) do
        OneNHC::Notifier.new(config).notify("msg", host: host, decision: decision)
      end
    ensure
      $stderr = old_stderr
    end

    assert true
  end

  def test_email_configuration_failure_is_logged
    old_stderr = $stderr
    $stderr = StringIO.new

    begin
      with_stub(
        OneNHC::EmailNotifier, :new,
        ->(*) { raise OneNHC::EmailNotifier::Error, "missing password" }
      ) do
        OneNHC::Notifier.new(config).notify("msg", host: host, decision: decision)
      end
      output = $stderr.string
    ensure
      $stderr = old_stderr
    end

    assert_includes output, "email notifications disabled"
    assert_includes output, "missing password"
  end

  def webhook_config(overrides = {})
    defaults = OneNHC::Config::DEFAULTS["controller"]
    notify = {
      "webhook" => "https://hooks.example.com/services/test",
      "email" => nil
    }.merge(overrides)

    OneNHC::Config.new(
      "groups" => {},
      "checks" => {},
      "controller" => defaults.merge("notify" => notify)
    )
  end

  def silent_stderr
    old_stderr = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = old_stderr
  end

  def test_webhook_retries_server_errors
    http  = FakeHTTP.new do |attempt|
      attempt < 3 ? error_response(Net::HTTPInternalServerError, 500) : ok_response
    end
    clock = FakeClock.new
    slept = []
    cfg   = webhook_config(
      "webhook_retries" => 2,
      "webhook_retry_delay" => 0.5,
      "webhook_min_interval" => 0
    )

    notifier = OneNHC::Notifier.new(
      cfg, clock: clock, sleeper: ->(seconds) { slept << seconds; clock.advance(seconds) }
    )

    with_stub(Net::HTTP, :new, http) do
      silent_stderr do
        notifier.notify("msg", host: host, decision: decision)
      end
    end

    assert_equal 3, http.requests
    assert_equal [0.5, 1.0], slept
  end

  def test_webhook_does_not_retry_client_errors
    http  = FakeHTTP.new { error_response(Net::HTTPBadRequest, 400) }
    slept = []
    cfg   = webhook_config(
      "webhook_retries" => 2,
      "webhook_retry_delay" => 0.5,
      "webhook_min_interval" => 0
    )

    notifier = OneNHC::Notifier.new(
      cfg, clock: FakeClock.new, sleeper: ->(seconds) { slept << seconds }
    )

    with_stub(Net::HTTP, :new, http) do
      silent_stderr do
        notifier.notify("msg", host: host, decision: decision)
      end
    end

    assert_equal 1, http.requests
    assert_empty slept
  end

  def test_webhook_retries_connection_errors
    http = FakeHTTP.new do |attempt|
      raise Errno::ECONNREFUSED, "boom" if attempt == 1

      ok_response
    end
    slept = []
    cfg   = webhook_config(
      "webhook_retries" => 1,
      "webhook_retry_delay" => 0.2,
      "webhook_min_interval" => 0
    )

    notifier = OneNHC::Notifier.new(
      cfg, clock: FakeClock.new, sleeper: ->(seconds) { slept << seconds }
    )

    with_stub(Net::HTTP, :new, http) do
      silent_stderr do
        notifier.notify("msg", host: host, decision: decision)
      end
    end

    assert_equal 2, http.requests
    assert_equal [0.2], slept
  end

  def test_webhook_gives_up_after_retries
    http = FakeHTTP.new { error_response(Net::HTTPInternalServerError, 500) }
    cfg  = webhook_config(
      "webhook_retries" => 1,
      "webhook_retry_delay" => 0,
      "webhook_min_interval" => 0
    )

    notifier = OneNHC::Notifier.new(cfg, clock: FakeClock.new, sleeper: ->(_) {})

    with_stub(Net::HTTP, :new, http) do
      silent_stderr do
        notifier.notify("msg", host: host, decision: decision)
      end
    end

    assert_equal 2, http.requests
  end

  def test_webhook_respects_retry_after_on_429
    http = FakeHTTP.new do |attempt|
      if attempt == 1
        response = error_response(Net::HTTPTooManyRequests, 429)
        response["Retry-After"] = "3"
        response
      else
        ok_response
      end
    end
    slept = []
    cfg   = webhook_config(
      "webhook_retries" => 1,
      "webhook_retry_delay" => 0.5,
      "webhook_min_interval" => 0
    )

    notifier = OneNHC::Notifier.new(
      cfg, clock: FakeClock.new, sleeper: ->(seconds) { slept << seconds }
    )

    with_stub(Net::HTTP, :new, http) do
      silent_stderr do
        notifier.notify("msg", host: host, decision: decision)
      end
    end

    assert_equal 2, http.requests
    assert_equal [3.0], slept
  end

  def test_webhook_rate_limit_waits_between_notifications
    http  = FakeHTTP.new { ok_response }
    clock = FakeClock.new
    slept = []
    cfg   = webhook_config(
      "webhook_retries" => 0,
      "webhook_min_interval" => 1.0
    )

    notifier = OneNHC::Notifier.new(
      cfg, clock: clock, sleeper: ->(seconds) { slept << seconds; clock.advance(seconds) }
    )

    with_stub(Net::HTTP, :new, http) do
      notifier.notify("one", host: host, decision: decision)
      notifier.notify("two", host: host, decision: decision)
    end

    assert_equal 2, http.requests
    assert_equal [1.0], slept
  end

  def test_webhook_rate_limit_can_be_disabled
    http  = FakeHTTP.new { ok_response }
    slept = []
    cfg   = webhook_config(
      "webhook_retries" => 0,
      "webhook_min_interval" => 0
    )

    notifier = OneNHC::Notifier.new(
      cfg, clock: FakeClock.new, sleeper: ->(seconds) { slept << seconds }
    )

    with_stub(Net::HTTP, :new, http) do
      notifier.notify("one", host: host, decision: decision)
      notifier.notify("two", host: host, decision: decision)
    end

    assert_equal 2, http.requests
    assert_empty slept
  end
end
