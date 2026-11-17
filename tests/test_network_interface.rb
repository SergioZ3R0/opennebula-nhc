# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestNetworkInterface < Minitest::Test
  def check
    OneNHC.checks.find { |candidate| candidate.id == "network-interface" }
  end

  def run_check(interfaces, tree: {}, missing_sysfs: false)
    Dir.mktmpdir do |dir|
      sysfs = missing_sysfs ? File.join(dir, "missing") : dir

      unless missing_sysfs
        tree.each do |name, values|
          path = File.join(sysfs, name)
          FileUtils.mkdir_p(path)
          values.each { |file, content| File.write(File.join(path, file), content) }
        end
      end

      config = OneNHC::Config.new(
        "checks" => {
          "network-interface" => {
            "enabled" => true,
            "sysfs" => sysfs,
            "interfaces" => interfaces
          }
        }
      )

      return check.call(config)
    end
  end

  def test_ok_when_interface_is_up
    result = run_check(
      [{ "name" => "onebr0" }],
      tree: { "onebr0" => { "operstate" => "up\n" } }
    )

    assert_equal :ok, result.status
    assert_equal 1, result.metrics["interfaces"]
  end

  def test_crit_when_interface_is_down
    result = run_check(
      [{ "name" => "onebr0" }],
      tree: { "onebr0" => { "operstate" => "down\n" } }
    )

    assert_equal :crit, result.status
    assert_includes result.message, "onebr0 is down"
  end

  def test_crit_when_interface_is_missing
    result = run_check([{ "name" => "bond0" }], tree: {})

    assert_equal :crit, result.status
    assert_includes result.message, "bond0 missing"
  end

  def test_crit_when_speed_is_too_low
    result = run_check(
      [{ "name" => "bond0", "speed" => 25_000 }],
      tree: { "bond0" => { "operstate" => "up\n", "speed" => "1000\n" } }
    )

    assert_equal :crit, result.status
    assert_includes result.message, "1000 Mb/s"
  end

  def test_crit_when_sysfs_is_missing
    result = run_check([{ "name" => "onebr0" }], missing_sysfs: true)

    assert_equal :crit, result.status
    assert_includes result.message, "sysfs not available"
  end

  def test_skip_without_interfaces
    result = run_check([])
    assert_equal :skip, result.status
  end
end
