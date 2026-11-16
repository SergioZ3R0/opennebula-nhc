# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestDatastoreMounts < Minitest::Test
  def check
    OneNHC.checks.find { |candidate| candidate.id == "datastore-mounts" }
  end

  def run_check(mounts_config, mounts_content = "")
    Dir.mktmpdir do |dir|
      proc_mounts = File.join(dir, "mounts")
      File.write(proc_mounts, mounts_content)

      config = OneNHC::Config.new(
        "proc_mounts" => proc_mounts,
        "checks" => {
          "datastore-mounts" => { "enabled" => true, "mounts" => mounts_config }
        }
      )

      return check.call(config)
    end
  end

  def test_ok_when_datastore_is_present_and_writable
    Dir.mktmpdir do |datastore|
      result = run_check([{ "path" => datastore, "must_be_mount" => false }])
      assert_equal :ok, result.status
    end
  end

  def test_crit_when_datastore_is_missing
    result = run_check([{ "path" => "/nonexistent/one-nhc-datastore", "must_be_mount" => false }])
    assert_equal :crit, result.status
    assert_includes result.message, "missing"
  end

  def test_crit_when_mount_is_required_but_absent
    Dir.mktmpdir do |datastore|
      result = run_check([{ "path" => datastore, "must_be_mount" => true }], "")
      assert_equal :crit, result.status
      assert_includes result.message, "not a mountpoint"
    end
  end

  def test_ok_when_required_mount_is_present
    Dir.mktmpdir do |datastore|
      proc_mounts = "tmpfs #{datastore} tmpfs rw 0 0\n"
      result = run_check([{ "path" => datastore, "must_be_mount" => true }], proc_mounts)
      assert_equal :ok, result.status
    end
  end

  def test_skip_when_no_mounts_configured
    result = run_check([], "")
    assert_equal :skip, result.status
  end
end
