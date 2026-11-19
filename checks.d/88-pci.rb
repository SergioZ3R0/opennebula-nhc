# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "pci",
  description: "Configured PCI devices are present and bound to the expected driver",
  severity: :crit,
  timeout: 10,
  tags: %w[hardware]
) do |ctx|
  options = ctx.config.check("pci")
  sysfs   = options["sysfs"] || "/sys/bus/pci/devices"
  devices = Array(options["devices"])

  ctx.skip!("no PCI devices configured") if devices.empty?
  ctx.crit!("PCI sysfs not available: #{sysfs}") unless File.directory?(sysfs)

  read_value = lambda do |path, name|
    file = File.join(path, name)
    File.file?(file) ? File.read(file).strip : ""
  end

  normalize_hex = lambda do |value, width|
    text = value.to_s.strip.downcase.sub(/\A0x/, "")
    if text.match?(/\A[0-9a-f]+\z/) && text.length < width
      text = text.rjust(width, "0")
    end
    text
  end

  driver_name = lambda do |path|
    link = File.join(path, "driver")
    File.symlink?(link) ? File.basename(File.readlink(link)).downcase : ""
  rescue StandardError
    ""
  end

  actual = Dir.glob(File.join(sysfs, "*")).select { |path| File.directory?(path) }.map do |path|
    {
      address: File.basename(path).downcase,
      vendor: normalize_hex.call(read_value.call(path, "vendor"), 4),
      device: normalize_hex.call(read_value.call(path, "device"), 4),
      class: normalize_hex.call(read_value.call(path, "class"), 6),
      driver: driver_name.call(path),
      iommu: File.symlink?(File.join(path, "iommu_group"))
    }
  end

  device_matches = lambda do |device, entry|
    address = entry["address"].to_s.strip.downcase
    if address.empty?
      vendor = normalize_hex.call(entry["vendor"], 4)
      dev    = normalize_hex.call(entry["device"], 4)
      next false if vendor.empty? || dev.empty?
      next false unless device[:vendor] == vendor && device[:device] == dev
    else
      next false unless device[:address] == address ||
                        device[:address].end_with?(":#{address}")
    end

    expected_class = entry["class"].to_s.strip.downcase.sub(/\A0x/, "")
    if !expected_class.empty? && !device[:class].start_with?(expected_class)
      next false
    end

    true
  end

  default_name = lambda do |entry|
    address = entry["address"].to_s.strip
    next address unless address.empty?

    "#{entry['vendor']}:#{entry['device']}"
  end

  problems = []
  matched_total = 0

  devices.each do |entry|
    name = entry["name"].to_s
    name = default_name.call(entry) if name.empty?

    address = entry["address"].to_s.strip
    vendor  = entry["vendor"].to_s.strip
    dev     = entry["device"].to_s.strip

    if address.empty? && (vendor.empty? || dev.empty?)
      problems << "#{name}: address or vendor/device required"
      next
    end

    matches = actual.select { |device| device_matches.call(device, entry) }
    expected_count = (entry["count"] || 1).to_i
    expected_count = 1 if expected_count < 1
    matched_total += matches.size

    if matches.size < expected_count
      problems << "#{name} missing (found #{matches.size}, expected #{expected_count})"
      next
    end

    expected_driver = entry["driver"].to_s.strip.downcase
    unless expected_driver.empty?
      wrong = matches.reject { |device| device[:driver] == expected_driver }
      unless wrong.empty?
        detail = wrong.map do |device|
          "#{device[:address]} driver #{device[:driver].empty? ? 'none' : device[:driver]}"
        end
        problems << "#{name} expected driver #{expected_driver} (#{detail.join(', ')})"
      end
    end

    next unless entry["iommu"] == true

    missing = matches.reject { |device| device[:iommu] }
    unless missing.empty?
      detail = missing.map { |device| device[:address] }
      problems << "#{name} missing IOMMU group (#{detail.join(', ')})"
    end
  end

  if problems.any?
    ctx.crit!(
      problems.join("; "),
      metrics: { "problems" => problems.size, "devices" => matched_total }
    )
  else
    ctx.ok!(
      "#{matched_total} PCI device(s) present and bound",
      metrics: { "devices" => matched_total }
    )
  end
end
