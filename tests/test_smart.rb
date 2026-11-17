# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestSmart < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end

    def exitstatus
      code
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "smart" }
  end

  def config(devices:, required: false, sudo: false)
    OneNHC::Config.new(
      "checks" => {
        "smart" => {
          "enabled" => true,
          "devices" => devices,
          "required" => required,
          "sudo" => sudo
        }
      }
    )
  end

  def responder(outputs)
    lambda do |command, **|
      outputs.fetch(command[2], ["", "unknown device", FakeStatus.new(2), :ok])
    end
  end

  def run_check(outputs, devices: ["/dev/sda"], required: false)
    with_stub(OneNHC::Shell, :which, "/usr/bin/smartctl") do
      with_stub(OneNHC::Shell, :capture, responder(outputs)) do
        return check.call(config(devices: devices, required: required))
      end
    end
  end

  def test_is_a_heavy_check
    assert check.heavy?
    assert_equal 1800, check.ttl
  end

  def test_ok_for_a_passed_disk
    result = run_check(
      {
        "/dev/sda" => [
          "SMART overall-health self-assessment test result: PASSED\n",
          "", FakeStatus.new(0), :ok
        ]
      }
    )

    assert_equal :ok, result.status
    assert_equal 1, result.metrics["disks"]
  end

  def test_ok_for_scsi_health_status
    result = run_check(
      { "/dev/sda" => ["SMART Health Status: OK\n", "", FakeStatus.new(0), :ok] }
    )

    assert_equal :ok, result.status
  end

  def test_crit_on_failed_health
    result = run_check(
      {
        "/dev/sda" => [
          "SMART overall-health self-assessment test result: FAILED!\n",
          "", FakeStatus.new(0), :ok
        ]
      }
    )

    assert_equal :crit, result.status
    assert_includes result.message, "FAILED"
  end

  def test_crit_on_a_failing_exit_bit
    result = run_check(
      {
        "/dev/sda" => [
          "SMART overall-health self-assessment test result: PASSED\n",
          "", FakeStatus.new(8), :ok
        ]
      }
    )

    assert_equal :crit, result.status
    assert_includes result.message, "SMART failing"
  end

  def test_unknown_on_permission_denied
    result = run_check(
      { "/dev/sda" => ["", "smartctl: Permission denied", FakeStatus.new(2), :ok] }
    )

    assert_equal :unknown, result.status
    assert_includes result.message, "permission denied"
  end

  def test_uses_sudo_when_configured
    seen = nil
    responder = lambda do |command, **|
      seen = command
      [
        "SMART overall-health self-assessment test result: PASSED\n",
        "", FakeStatus.new(0), :ok
      ]
    end

    with_stub(OneNHC::Shell, :which, "/usr/bin/smartctl") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config(devices: ["/dev/sda"], sudo: true))
        assert_equal :ok, result.status
      end
    end

    assert_equal ["sudo", "-n", "smartctl", "-H", "/dev/sda"], seen
  end

  def test_skip_without_smartctl
    with_stub(OneNHC::Shell, :which, nil) do
      result = check.call(config(devices: ["/dev/sda"]))
      assert_equal :skip, result.status
      assert_includes result.message, "smartctl not installed"
    end
  end

  def test_crit_without_smartctl_when_required
    with_stub(OneNHC::Shell, :which, nil) do
      result = check.call(config(devices: ["/dev/sda"], required: true))
      assert_equal :crit, result.status
      assert_includes result.message, "smartctl not installed"
    end
  end

  def test_skip_without_devices
    assert_equal :skip, check.call(config(devices: [])).status
  end
end
