# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class TestPci < Minitest::Test
  def setup
    @dir   = Dir.mktmpdir
    @sysfs = File.join(@dir, "pci")
    @iommu = File.join(@dir, "iommu", "1")
    FileUtils.mkdir_p(@sysfs)
    FileUtils.mkdir_p(@iommu)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def check
    OneNHC.checks.find { |candidate| candidate.id == "pci" }
  end

  def config(overrides = {})
    options = {
      "enabled" => true,
      "sysfs" => @sysfs,
      "devices" => []
    }.merge(overrides)

    OneNHC::Config.new("checks" => { "pci" => options })
  end

  def add_device(address, vendor:, device:, klass: "030000", driver: nil, iommu: false)
    path = File.join(@sysfs, address)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "vendor"), "0x#{vendor}\n")
    File.write(File.join(path, "device"), "0x#{device}\n")
    File.write(File.join(path, "class"), "0x#{klass}\n")

    if driver
      driver_dir = File.join(@dir, "drivers", driver)
      FileUtils.mkdir_p(driver_dir)
      File.symlink(driver_dir, File.join(path, "driver"))
    end

    File.symlink(@iommu, File.join(path, "iommu_group")) if iommu
  end

  def gpu_device(driver: "vfio-pci", iommu: true)
    add_device(
      "0000:82:00.0",
      vendor: "10de", device: "24b0", driver: driver, iommu: iommu
    )
  end

  def audio_device(driver: "vfio-pci", iommu: true)
    add_device(
      "0000:82:00.1",
      vendor: "10de", device: "228b", klass: "040300", driver: driver, iommu: iommu
    )
  end

  def gpu_entry(overrides = {})
    {
      "name" => "RTX A4000",
      "vendor" => "10de",
      "device" => "24b0",
      "driver" => "vfio-pci",
      "iommu" => true
    }.merge(overrides)
  end

  def test_ok_when_devices_are_present_and_bound
    gpu_device
    audio_device

    result = check.call(
      config(
        "devices" => [
          gpu_entry,
          {
            "name" => "RTX A4000 audio",
            "vendor" => "10de",
            "device" => "228b",
            "driver" => "vfio-pci",
            "iommu" => true
          }
        ]
      )
    )

    assert_equal :ok, result.status
    assert_equal 2, result.metrics["devices"]
    assert_includes result.message, "2 PCI device(s)"
  end

  def test_crit_when_a_device_is_missing
    gpu_device

    result = check.call(
      config(
        "devices" => [
          gpu_entry,
          { "name" => "audio", "vendor" => "10de", "device" => "228b" }
        ]
      )
    )

    assert_equal :crit, result.status
    assert_includes result.message, "audio missing"
  end

  def test_crit_when_the_driver_does_not_match
    gpu_device(driver: "nvidia")

    result = check.call(config("devices" => [gpu_entry]))

    assert_equal :crit, result.status
    assert_includes result.message, "expected driver vfio-pci"
    assert_includes result.message, "nvidia"
  end

  def test_crit_when_iommu_group_is_missing
    gpu_device(iommu: false)

    result = check.call(config("devices" => [gpu_entry]))

    assert_equal :crit, result.status
    assert_includes result.message, "missing IOMMU group"
  end

  def test_iommu_check_can_be_disabled
    gpu_device(iommu: false)

    result = check.call(
      config("devices" => [gpu_entry("iommu" => false)])
    )

    assert_equal :ok, result.status
  end

  def test_skip_without_devices
    result = check.call(config)

    assert_equal :skip, result.status
    assert_includes result.message, "no PCI devices configured"
  end

  def test_crit_when_sysfs_is_missing
    result = check.call(
      config(
        "sysfs" => File.join(@dir, "missing"),
        "devices" => [gpu_entry]
      )
    )

    assert_equal :crit, result.status
    assert_includes result.message, "PCI sysfs not available"
  end

  def test_match_by_address
    gpu_device

    result = check.call(
      config(
        "devices" => [
          { "name" => "GPU at 82:00.0", "address" => "82:00.0", "driver" => "vfio-pci" }
        ]
      )
    )

    assert_equal :ok, result.status
  end

  def test_count_requires_all_expected_devices
    gpu_device
    add_device(
      "0000:83:00.0",
      vendor: "10de", device: "24b0", driver: "vfio-pci", iommu: true
    )

    ok = check.call(config("devices" => [gpu_entry("count" => 2)]))
    assert_equal :ok, ok.status

    crit = check.call(config("devices" => [gpu_entry("count" => 3)]))
    assert_equal :crit, crit.status
    assert_includes crit.message, "expected 3"
  end

  def test_invalid_entry
    result = check.call(config("devices" => [{ "name" => "broken" }]))

    assert_equal :crit, result.status
    assert_includes result.message, "address or vendor/device required"
  end

  def test_class_filter
    gpu_device

    ok = check.call(
      config(
        "devices" => [gpu_entry("class" => "0300")]
      )
    )
    assert_equal :ok, ok.status

    crit = check.call(
      config(
        "devices" => [gpu_entry("class" => "0200")]
      )
    )
    assert_equal :crit, crit.status
  end
end
