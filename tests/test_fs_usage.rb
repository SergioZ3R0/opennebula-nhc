# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestFsUsage < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end

    def exitstatus
      code
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "fs-usage" }
  end

  def config(overrides = {})
    OneNHC::Config.new(
      "checks" => {
        "fs-usage" => {
          "enabled" => true,
          "mounts" => [{ "path" => "/data" }]
        }.merge(overrides)
      }
    )
  end

  def df_output(usage)
    <<~DF
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/sda1 1000 900 100 #{usage}% /data
    DF
  end

  def run_check(overrides = {})
    check.call(config(overrides))
  end

  def test_ok_below_warn
    responder = ->(_command, **) { [df_output(50), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :capture, responder) do
      result = run_check
      assert_equal :ok, result.status
      assert_equal 1, result.metrics["mounts"]
    end
  end

  def test_warn_at_the_warn_threshold
    responder = ->(_command, **) { [df_output(90), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :capture, responder) do
      result = run_check("warn" => 90, "crit" => 95)
      assert_equal :warn, result.status
      assert_includes result.message, "90%"
    end
  end

  def test_crit_at_the_crit_threshold
    responder = ->(_command, **) { [df_output(95), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :capture, responder) do
      result = run_check("warn" => 90, "crit" => 95)
      assert_equal :crit, result.status
      assert_includes result.message, "95%"
    end
  end

  def test_checks_inodes
    responder = lambda do |command, **|
      usage = command[1] == "-Pi" ? 97 : 50
      [df_output(usage), "", FakeStatus.new(0), :ok]
    end

    with_stub(OneNHC::Shell, :capture, responder) do
      result = run_check("check_inodes" => true)
      assert_equal :crit, result.status
      assert_includes result.message, "inodes 97%"
    end
  end

  def test_crit_on_timeout
    responder = ->(_command, **) { [nil, nil, nil, :timeout] }

    with_stub(OneNHC::Shell, :capture, responder) do
      result = run_check
      assert_equal :crit, result.status
      assert_includes result.message, "timed out"
    end
  end

  def test_crit_when_df_fails
    responder = ->(_command, **) { ["", "df: /data: No such file", FakeStatus.new(1), :ok] }

    with_stub(OneNHC::Shell, :capture, responder) do
      result = run_check
      assert_equal :crit, result.status
      assert_includes result.message, "No such file"
    end
  end

  def test_skip_without_mounts
    result = run_check("mounts" => [])
    assert_equal :skip, result.status
  end
end
