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

  def test_is_a_fast_check
    refute check.heavy?
  end

  def list_output(count)
    (0...count).map { |i| "GPU #{i}: NVIDIA A100 (UUID: GPU-#{i})\n" }.join
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

  def mig_output(physical, mig)
    lines = (0...physical).map { |i| "GPU #{i}: NVIDIA A100 (UUID: GPU-#{i})\n" }
    partitions = (0...mig).map do |i|
      "  MIG 1g.5gb Device #{i}: (UUID: MIG-#{i})\n"
    end
    (lines + partitions).join
  end

  def test_mig_partitions_are_counted_by_default
    responder = ->(_command, **) { [mig_output(2, 4), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("count" => 6))
        assert_equal :ok, result.status
        assert_equal 6, result.metrics["gpus"]
        assert_equal 2, result.metrics["physical_gpus"]
        assert_equal 4, result.metrics["mig"]
        assert_includes result.message, "2 physical, 4 MIG"
      end
    end
  end

  def test_count_mig_false_counts_physical_gpus_only
    responder = ->(_command, **) { [mig_output(2, 4), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("count" => 2, "count_mig" => false))
        assert_equal :ok, result.status
        assert_equal 2, result.metrics["gpus"]
        assert_equal 4, result.metrics["mig"]
      end
    end
  end

  def test_mig_count_can_trigger_a_crit
    responder = ->(_command, **) { [mig_output(1, 2), "", FakeStatus.new(0), :ok] }

    with_stub(OneNHC::Shell, :which, "/usr/bin/nvidia-smi") do
      with_stub(OneNHC::Shell, :capture, responder) do
        result = check.call(config("count" => 1))
        assert_equal :crit, result.status
        assert_includes result.message, "found 3"
      end
    end
  end
end
