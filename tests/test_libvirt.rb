# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestLibvirt < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "libvirt" }
  end

  def config
    OneNHC::Config.new(
      "checks" => {
        "libvirt" => { "enabled" => true, "uri" => "qemu:///system", "timeout" => 2 }
      }
    )
  end

  def test_ok_when_virsh_lists_domains
    output = " Id   Name\n 1    vm-a\n 2    vm-b\n"

    with_stub(OneNHC::Shell, :which, "/usr/bin/virsh") do
      with_stub(OneNHC::Shell, :capture, [output, "", FakeStatus.new(0), :ok]) do
        result = check.call(config)

        assert_equal :ok, result.status
        assert_equal 2, result.metrics["domains"]
      end
    end
  end

  def test_crit_on_error
    error = "error: failed to connect to the hypervisor"

    with_stub(OneNHC::Shell, :which, "/usr/bin/virsh") do
      with_stub(OneNHC::Shell, :capture, ["", error, FakeStatus.new(1), :ok]) do
        result = check.call(config)

        assert_equal :crit, result.status
        assert_includes result.message, "failed to connect"
      end
    end
  end

  def test_crit_on_timeout
    with_stub(OneNHC::Shell, :which, "/usr/bin/virsh") do
      with_stub(OneNHC::Shell, :capture, [nil, nil, nil, :timeout]) do
        result = check.call(config)

        assert_equal :crit, result.status
        assert_includes result.message, "timed out"
      end
    end
  end

  def test_skip_when_virsh_missing
    with_stub(OneNHC::Shell, :which, nil) do
      result = check.call(config)
      assert_equal :skip, result.status
    end
  end
end
