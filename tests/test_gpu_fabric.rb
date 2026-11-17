# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestGpuFabric < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "gpu-fabric" }
  end

  def config(overrides = {})
    OneNHC::Config.new(
      "checks" => { "gpu-fabric" => { "enabled" => true }.merge(overrides) }
    )
  end

  def list_output(count)
    (0...count).map { |i| "GPU #{i}: NVIDIA A100 (UUID: GPU-#{i})\n" }.join
  end

  def fabric_output(state: "Completed", status: "Success")
    <<~OUT
      GPU 00000000:01:00.0
          Product Name : NVIDIA A100
          Fabric
              State                             : #{state}
              Status                            : #{status}
    OUT
  end

  def responder(count:, state: "Completed", status: "Success")
    lambda do |command, **|
      if command[1] == "-L"
        [list_output(count), "", FakeStatus.new(0), :ok]
      else
        [fabric_output(state: state, status: status), "", FakeStatus.new(0), :ok]
      end
    end
  end

  def test_is_a_heavy_check
    assert check.heavy?
    assert_equal 1800, check.ttl
  end

  def test_ok_when_fabric_is_healthy
    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder(count: 2)) do
        result = check.call(config)
        assert_equal :ok, result.status
        assert_equal 2, result.metrics["gpus"]
      end
    end
  end

  def test_crit_when_fabric_fails
    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(
        OneNHC::Shell, :capture,
        responder(count: 1, state: "Failed", status: "Error")
      ) do
        result = check.call(config)
        assert_equal :crit, result.status
        assert_includes result.message, "Fabric State=Failed"
      end
    end
  end

  def test_unknown_when_fabric_block_is_missing
    responder = lambda do |command, **|
      if command[1] == "-L"
        [list_output(1), "", FakeStatus.new(0), :ok]
      else
        ["GPU 0\n  Product Name : NVIDIA A100\n", "", FakeStatus.new(0), :ok]
      end
    end

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config)
        assert_equal :unknown, result.status
        assert_includes result.message, "Fabric information missing"
      end
    end
  end

  def test_unknown_on_fabric_query_timeout
    responder = lambda do |command, **|
      if command[1] == "-L"
        [list_output(1), "", FakeStatus.new(0), :ok]
      else
        [nil, nil, nil, :timeout]
      end
    end

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config)
        assert_equal :unknown, result.status
        assert_includes result.message, "timed out"
      end
    end
  end

  def test_skip_without_nvidia_smi
    with_stub(OneNHC::Shell, :which, nil) do
      assert_equal :skip, check.call(config).status
    end
  end

  def test_crit_without_nvidia_smi_when_required
    with_stub(OneNHC::Shell, :which, nil) do
      result = check.call(config("required" => true))
      assert_equal :crit, result.status
      assert_includes result.message, "nvidia-smi not installed"
    end
  end

  def test_skip_without_gpus
    responder = ->(_command, **) { ["", "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        assert_equal :skip, check.call(config).status
      end
    end
  end
end
