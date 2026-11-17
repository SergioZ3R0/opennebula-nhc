# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"

class TestGpu < Minitest::Test
  FakeStatus = Struct.new(:code) do
    def success?
      code.zero?
    end
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "gpu" }
  end

  def config(overrides = {})
    OneNHC::Config.new(
      "checks" => { "gpu" => { "enabled" => true }.merge(overrides) }
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

  def test_ok_when_the_expected_gpus_are_present
    responder = ->(command, **) { [list_output(2), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("count" => 2))
        assert_equal :ok, result.status
        assert_equal 2, result.metrics["gpus"]
      end
    end
  end

  def test_crit_when_the_gpu_count_differs
    responder = ->(_command, **) { [list_output(1), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("count" => 2))
        assert_equal :crit, result.status
        assert_includes result.message, "expected 2 GPU(s), found 1"
      end
    end
  end

  def test_fabric_success
    responder = lambda do |command, **|
      if command[1] == "-L"
        [list_output(2), "", FakeStatus.new(0), :ok]
      else
        [fabric_output, "", FakeStatus.new(0), :ok]
      end
    end

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("count" => 2, "fabric" => true))
        assert_equal :ok, result.status
      end
    end
  end

  def test_fabric_failure
    responder = lambda do |command, **|
      if command[1] == "-L"
        [list_output(1), "", FakeStatus.new(0), :ok]
      else
        [fabric_output(state: "Failed", status: "Error"), "", FakeStatus.new(0), :ok]
      end
    end

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("count" => 1, "fabric" => true))
        assert_equal :crit, result.status
        assert_includes result.message, "Fabric State=Failed"
      end
    end
  end

  def test_skip_without_nvidia_smi
    with_stub(OneNHC::Shell, :which, nil) do
      result = check.call(config)
      assert_equal :skip, result.status
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
        result = check.call(config)
        assert_equal :skip, result.status
      end
    end
  end

  def test_crit_on_list_timeout
    responder = ->(_command, **) { [nil, nil, nil, :timeout] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config)
        assert_equal :crit, result.status
        assert_includes result.message, "timed out"
      end
    end
  end
end
