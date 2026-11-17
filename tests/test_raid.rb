# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestRaid < Minitest::Test
  def check
    OneNHC.checks.find { |candidate| candidate.id == "raid" }
  end

  def run_check(arrays: {}, mdstat: "")
    Dir.mktmpdir do |dir|
      sysfs = File.join(dir, "block")
      FileUtils.mkdir_p(sysfs)

      arrays.each do |name, degraded|
        path = File.join(sysfs, name, "md")
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "degraded"), "#{degraded}\n")
      end

      mdstat_path = File.join(dir, "mdstat")
      File.write(mdstat_path, mdstat)

      config = OneNHC::Config.new(
        "checks" => {
          "raid" => {
            "enabled" => true,
            "sysfs" => sysfs,
            "mdstat" => mdstat_path
          }
        }
      )

      return check.call(config)
    end
  end

  def test_ok_when_arrays_are_healthy
    result = run_check(arrays: { "md0" => 0, "md1" => 0 })

    assert_equal :ok, result.status
    assert_equal 2, result.metrics["arrays"]
  end

  def test_crit_when_an_array_is_degraded
    result = run_check(arrays: { "md0" => 1 })

    assert_equal :crit, result.status
    assert_includes result.message, "md0 degraded"
  end

  def test_crit_from_mdstat_when_sysfs_has_no_arrays
    mdstat = <<~MDSTAT
      Personalities : [raid1]
      md0 : active raid1 sda1[0] sdb1[1](F)
            1953382464 blocks super 1.2 [2/1] [U_]
    MDSTAT

    result = run_check(mdstat: mdstat)

    assert_equal :crit, result.status
    assert_includes result.message, "mdstat"
  end

  def test_skip_without_arrays
    result = run_check

    assert_equal :skip, result.status
  end
end
