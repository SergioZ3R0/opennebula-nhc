# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "json"

class TestAdapters < Minitest::Test
  def results
    [
      OneNHC::Result.new(check_id: "fs-ro", status: :ok, message: "fine"),
      OneNHC::Result.new(
        check_id: "datastore-mounts", status: :crit,
        message: "missing \"/data\"\nreally"
      )
    ]
  end

  def test_on_monitor_attributes
    output = OneNHC::Adapters::OnMonitor.render(results)

    assert_includes output, 'NHC_STATUS="CRIT"'
    assert_includes output, 'NHC_FS_RO="OK"'
    assert_includes output, 'NHC_DATASTORE_MOUNTS="CRIT"'
    assert_includes output, 'NHC_CHECK_COUNT="2"'
  end

  def test_on_monitor_sanitizes_messages
    output = OneNHC::Adapters::OnMonitor.render(results)
    line   = output.lines.find { |l| l.start_with?("NHC_DATASTORE_MOUNTS_MSG=") }

    refute_nil line
    line = line.chomp

    assert_equal 2, line.count('"')
    refute_includes line, "\n"
    assert_includes line, "missing '"
  end

  def test_on_monitor_truncates_long_messages
    long = "x" * 500
    output = OneNHC::Adapters::OnMonitor.render(
      [OneNHC::Result.new(check_id: "big", status: :crit, message: long)]
    )
    line  = output.lines.find { |l| l.start_with?("NHC_BIG_MSG=") }.chomp
    value = line[/"(.*)"$/, 1]

    assert_operator value.length, :<=, OneNHC::Adapters::OnMonitor::MAX_MESSAGE
  end

  def test_json_is_parseable
    data = JSON.parse(OneNHC::Adapters::Json.render(results))

    assert_equal "CRIT", data["status"]
    assert_equal "fs-ro", data["checks"][0]["id"]
    assert_equal "datastore-mounts", data["checks"][1]["id"]
  end

  def test_human_contains_summary
    output = OneNHC::Adapters::Human.render(results)

    assert_includes output, "NHC_STATUS=CRIT"
    assert_includes output, "fs-ro"
  end
end
