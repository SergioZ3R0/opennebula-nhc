# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestInfiniband < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "infiniband" }
  end

  def build_tree(sysfs, tree)
    tree.each do |device, data|
      device_path = File.join(sysfs, device)
      FileUtils.mkdir_p(device_path)

      data.each do |key, value|
        if key == "ports"
          value.each do |port, files|
            port_path = File.join(device_path, "ports", port)
            FileUtils.mkdir_p(port_path)
            files.each { |name, content| File.write(File.join(port_path, name), content) }
          end
        else
          File.write(File.join(device_path, key), value)
        end
      end
    end
  end

  def run_check(devices:, tree: {}, missing_sysfs: false, require_openibd: false)
    Dir.mktmpdir do |dir|
      sysfs = missing_sysfs ? File.join(dir, "missing") : dir
      build_tree(sysfs, tree) unless missing_sysfs

      config = OneNHC::Config.new(
        "checks" => {
          "infiniband" => {
            "enabled" => true,
            "sysfs" => sysfs,
            "devices" => devices,
            "require_openibd" => require_openibd
          }
        }
      )

      return check.call(config)
    end
  end

  def healthy_tree
    {
      "mlx5_0" => {
        "fw_ver" => "28.45.1200\n",
        "ports" => {
          "1" => {
            "state" => "4: ACTIVE\n",
            "phys_state" => "5: LinkUp\n",
            "rate" => "400 Gb/sec (4X EDR)\n"
          }
        }
      }
    }
  end

  def device
    { "device" => "mlx5_0", "port" => 1, "rate" => 400, "firmware" => "28.45.1200" }
  end

  def test_ok_when_port_is_active
    result = run_check(devices: [device], tree: healthy_tree)

    assert_equal :ok, result.status
    assert_equal 1, result.metrics["ports"]
  end

  def test_crit_when_port_is_down
    tree = healthy_tree
    tree["mlx5_0"]["ports"]["1"]["state"] = "1: DOWN\n"

    result = run_check(devices: [device], tree: tree)

    assert_equal :crit, result.status
    assert_includes result.message, "DOWN"
  end

  def test_crit_when_rate_is_too_low
    tree = healthy_tree
    tree["mlx5_0"]["ports"]["1"]["rate"] = "200 Gb/sec\n"

    result = run_check(devices: [device], tree: tree)

    assert_equal :crit, result.status
    assert_includes result.message, "200 < 400"
  end

  def test_crit_when_firmware_differs
    tree = healthy_tree
    tree["mlx5_0"]["fw_ver"] = "1.2.3\n"

    result = run_check(devices: [device], tree: tree)

    assert_equal :crit, result.status
    assert_includes result.message, "firmware 1.2.3"
  end

  def test_crit_when_device_is_missing
    result = run_check(devices: [device], tree: {})

    assert_equal :crit, result.status
    assert_includes result.message, "mlx5_0/1 missing"
  end

  def test_crit_when_sysfs_is_missing_but_devices_are_configured
    result = run_check(devices: [device], missing_sysfs: true)

    assert_equal :crit, result.status
    assert_includes result.message, "sysfs not available"
  end

  def test_skip_without_devices_and_sysfs
    result = run_check(devices: [], missing_sysfs: true)

    assert_equal :skip, result.status
  end

  def test_discovers_ports_when_no_devices_are_configured
    result = run_check(devices: [], tree: healthy_tree)

    assert_equal :ok, result.status
    assert_equal 1, result.metrics["ports"]
  end

  def test_openibd_inactive_is_a_problem
    with_stub(OneNHC::Shell, :capture, [nil, nil, FakeStatus.new(3), :ok]) do
      result = run_check(devices: [device], tree: healthy_tree, require_openibd: true)
      assert_equal :crit, result.status
      assert_includes result.message, "openibd"
    end
  end

  def test_openibd_unavailable_is_unknown
    with_stub(OneNHC::Shell, :capture, [nil, nil, nil, :notfound]) do
      result = run_check(devices: [device], tree: healthy_tree, require_openibd: true)
      assert_equal :unknown, result.status
      assert_includes result.message, "systemctl not found"
    end
  end
end
