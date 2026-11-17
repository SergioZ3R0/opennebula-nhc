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
end
