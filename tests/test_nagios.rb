# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestNagios < Minitest::Test
  def result(id, status, message = "")
    OneNHC::Result.new(check_id: id, status: status, message: message)
  end

  def host(status, details)
    OneNHC::HostView.new(
      id: 0,
      name: "node1",
      status: status,
      state: OneNHC::Controller::HOST_MONITORED,
      sample: 1,
      details: details,
      cluster: "default"
    )
  end

  def test_check_ok_output_and_perfdata
    output = OneNHC::Adapters::Nagios.check(
      [result("fs-ro", :ok), result("gpu", :skip)]
    )

    assert_includes output, "OK - 2 check(s) OK"
    assert_includes output, "checks=2"
    assert_includes output, "ok=1"
    assert_includes output, "skip=1"
    assert_includes output, "All checks passed"
  end

  def test_check_crit_lists_the_failing_check
    output = OneNHC::Adapters::Nagios.check(
      [
        result("fs-ro", :ok),
        result("network-interface", :crit, "nhc-test0 is down (expected up)")
      ]
    )

    assert_includes output, "CRITICAL - 1/2 check(s) not OK (network-interface)"
    assert_includes output, "network-interface: CRIT nhc-test0 is down (expected up)"
    assert_includes output, "crit=1"
  end

  def test_check_warn_output
    output = OneNHC::Adapters::Nagios.check(
      [result("fs-usage", :warn, "/var 92% >= 90%")]
    )

    assert_includes output, "WARNING - 1/1 check(s) not OK (fs-usage)"
    assert_includes output, "fs-usage: WARN /var 92% >= 90%"
  end

  def test_hosts_crit_output_includes_the_failing_check
    node = host(
      "CRIT",
      {
        "NHC_STATUS" => "CRIT",
        "NHC_CHECK_COUNT" => "12",
        "NHC_CRIT" => "1",
        "NHC_WARN" => "0",
        "NHC_OK" => "11",
        "NHC_NETWORK_INTERFACE" => "CRIT",
        "NHC_NETWORK_INTERFACE_MSG" => "nhc-test0 is down (expected up)"
      }
    )

    output = OneNHC::Adapters::Nagios.hosts([node])

    assert_includes output, "CRITICAL - 1/1 host(s) not OK (node1)"
    assert_includes output, "hosts=1"
    assert_includes output, "crit=1"
    assert_includes output, "node1: CRIT network-interface: nhc-test0 is down (expected up)"
  end

  def test_hosts_ok_output
    node = host("OK", { "NHC_STATUS" => "OK", "NHC_CHECK_COUNT" => "12" })

    output = OneNHC::Adapters::Nagios.hosts([node])

    assert_includes output, "OK - all 1 host(s) OK"
    assert_includes output, "All hosts OK"
  end

  def test_exit_codes
    adapter = OneNHC::Adapters::Nagios

    assert_equal 0, adapter.exit_code([:ok])
    assert_equal 0, adapter.exit_code([:skip])
    assert_equal 1, adapter.exit_code([:warn])
    assert_equal 2, adapter.exit_code([:crit])
    assert_equal 3, adapter.exit_code([:unknown])
    assert_equal 2, adapter.exit_code(%i[ok crit])
  end

  def test_unknown_status_is_normalized
    node = host("BROKEN", {})

    assert_equal 3, OneNHC::Adapters::Nagios.exit_code([node.status])
    assert_includes OneNHC::Adapters::Nagios.hosts([node]), "UNKNOWN"
  end
end
