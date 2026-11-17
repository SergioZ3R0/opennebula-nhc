# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestService < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "service" }
  end

  def run_check(services, responder)
    config = OneNHC::Config.new(
      "checks" => {
        "service" => { "enabled" => true, "services" => services }
      }
    )

    with_stub(OneNHC::Shell, :capture, responder) { return check.call(config) }
  end

  def test_ok_when_all_services_are_active
    responder = lambda do |command, **|
      active = command[0] == "systemctl" ? command[3] == "openibd" : command[2] == "slurmd"
      [nil, nil, FakeStatus.new(active ? 0 : 1), :ok]
    end

    result = run_check(
      [
        { "name" => "openibd", "type" => "systemd" },
        { "name" => "slurmd", "type" => "process" }
      ],
      responder
    )

    assert_equal :ok, result.status
    assert_equal 2, result.metrics["services"]
  end

  def test_crit_when_a_systemd_service_is_inactive
    responder = ->(_command, **) { [nil, nil, FakeStatus.new(3), :ok] }

    result = run_check([{ "name" => "openibd", "type" => "systemd" }], responder)

    assert_equal :crit, result.status
    assert_includes result.message, "openibd is not active"
  end

  def test_crit_when_a_process_is_missing
    responder = ->(_command, **) { [nil, nil, FakeStatus.new(1), :ok] }

    result = run_check([{ "name" => "slurmd", "type" => "process" }], responder)

    assert_equal :crit, result.status
    assert_includes result.message, "slurmd process not found"
  end

  def test_skip_when_tool_is_missing
    responder = ->(_command, **) { [nil, nil, nil, :notfound] }

    result = run_check([{ "name" => "openibd", "type" => "systemd" }], responder)

    assert_equal :skip, result.status
    assert_includes result.message, "systemctl not found"
  end

  def test_unknown_when_some_services_cannot_be_checked
    responder = lambda do |command, **|
      if command[0] == "systemctl"
        [nil, nil, nil, :notfound]
      else
        [nil, nil, FakeStatus.new(0), :ok]
      end
    end

    result = run_check(
      [
        { "name" => "openibd", "type" => "systemd" },
        { "name" => "slurmd", "type" => "process" }
      ],
      responder
    )

    assert_equal :unknown, result.status
    assert_equal 1, result.metrics["skipped"]
  end

  def test_crit_on_unknown_service_type
    responder = ->(_command, **) { [nil, nil, FakeStatus.new(0), :ok] }

    result = run_check([{ "name" => "weird", "type" => "magic" }], responder)

    assert_equal :crit, result.status
    assert_includes result.message, "unknown type"
  end

  def test_skip_without_services
    config = OneNHC::Config.new(
      "checks" => { "service" => { "enabled" => true, "services" => [] } }
    )

    assert_equal :skip, check.call(config).status
  end
end
