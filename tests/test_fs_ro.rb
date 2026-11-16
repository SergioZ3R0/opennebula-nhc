# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestFsRo < Minitest::Test
  def check
    OneNHC.checks.find { |candidate| candidate.id == "fs-ro" }
  end

  def run_check(mounts_content)
    Dir.mktmpdir do |dir|
      proc_mounts = File.join(dir, "mounts")
      File.write(proc_mounts, mounts_content)

      config = OneNHC::Config.new(
        "proc_mounts" => proc_mounts,
        "checks" => { "fs-ro" => { "enabled" => true, "allowlist" => [] } }
      )

      return check.call(config)
    end
  end

  def test_ok_when_all_real_filesystems_are_rw
    result = run_check(<<~MOUNTS)
      proc /proc proc rw,nosuid 0 0
      sysfs /sys sysfs rw 0 0
      /dev/sda1 / ext4 rw,relatime 0 0
      /dev/sdb1 /data ext4 rw,relatime 0 0
    MOUNTS

    assert_equal :ok, result.status
  end

  def test_crit_when_real_filesystem_is_read_only
    result = run_check(<<~MOUNTS)
      proc /proc proc rw 0 0
      /dev/sda1 / ext4 rw,relatime 0 0
      /dev/sdb1 /data ext4 ro,relatime 0 0
    MOUNTS

    assert_equal :crit, result.status
    assert_includes result.message, "/data"
    assert_equal 1, result.metrics["read_only_mounts"]
  end

  def test_ignores_pseudo_filesystems
    result = run_check(<<~MOUNTS)
      proc /proc proc ro 0 0
      sysfs /sys sysfs ro 0 0
      /dev/sda1 / ext4 rw 0 0
    MOUNTS

    assert_equal :ok, result.status
  end
end
