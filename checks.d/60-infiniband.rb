# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
# frozen_string_literal: true

OneNHC.check(
  id: "infiniband",
  description: "InfiniBand ports are active at the expected rate and firmware",
  severity: :crit,
  timeout: 15,
  tags: %w[network hardware]
) do |ctx|
  options    = ctx.config.check("infiniband")
  sysfs      = options["sysfs"] || "/sys/class/infiniband"
  configured = Array(options["devices"])

  read_value = lambda do |path|
    File.file?(path) ? File.read(path).strip : ""
  end

  normalize = lambda do |value|
    value.to_s.sub(/\A\d+:\s*/, "").upcase
  end

  discover = lambda do
    Dir.glob(File.join(sysfs, "*", "ports", "*")).sort.map do |path|
      device = File.basename(File.dirname(File.dirname(path)))
      port   = File.basename(path)
      { "device" => device, "port" => port.to_i }
    end
  end

  if configured.empty?
    ctx.skip!("InfiniBand sysfs not available") unless File.directory?(sysfs)
    devices = discover.call
    ctx.skip!("no InfiniBand devices") if devices.empty?
  else
    ctx.crit!("InfiniBand sysfs not available") unless File.directory?(sysfs)
    devices = configured
  end

  problems = []
  notes    = []

  if options["require_openibd"]
    _out, _err, status, state = OneNHC::Shell.capture(
      ["systemctl", "is-active", "--quiet", "openibd"], timeout: 5
    )

    case state
    when :notfound then notes << "systemctl not found (openibd not checked)"
    when :timeout then notes << "openibd status timed out"
    else problems << "openibd.service is not active" unless status&.success?
    end
  end

  devices.each do |entry|
    device = entry["device"].to_s
    port   = (entry["port"] || 1).to_i

    if device.empty?
      problems << "empty InfiniBand device in config"
      next
    end

    base = File.join(sysfs, device, "ports", port.to_s)
    unless File.directory?(base)
      problems << "#{device}/#{port} missing"
      next
    end

    expected_state = (entry["state"] || "ACTIVE").to_s.upcase
    actual_state   = normalize.call(read_value.call(File.join(base, "state")))
    if actual_state != expected_state
      shown = actual_state.empty? ? "unknown" : actual_state
      problems << "#{device}/#{port} state #{shown} (expected #{expected_state})"
    end

    phys = normalize.call(read_value.call(File.join(base, "phys_state")))
    if !phys.empty? && phys != "LINKUP"
      problems << "#{device}/#{port} phys_state #{phys} (expected LINKUP)"
    end

    if entry.key?("rate")
      expected_rate = entry["rate"].to_s.to_i
      rate          = read_value.call(File.join(base, "rate")).to_i

      if expected_rate <= 0
        problems << "#{device}/#{port} invalid rate in config"
      elsif rate <= 0
        problems << "#{device}/#{port} rate unknown (expected >= #{expected_rate})"
      elsif rate < expected_rate
        problems << "#{device}/#{port} rate #{rate} < #{expected_rate}"
      end
    end

    next unless entry.key?("firmware")

    expected_fw = entry["firmware"].to_s
    actual_fw   = read_value.call(File.join(sysfs, device, "fw_ver"))

    if expected_fw.empty?
      problems << "#{device}/#{port} invalid firmware in config"
    elsif actual_fw != expected_fw
      shown = actual_fw.empty? ? "unknown" : actual_fw
      problems << "#{device}/#{port} firmware #{shown} (expected #{expected_fw})"
    end
  end

  if problems.any?
    ctx.crit!(problems.join("; "), metrics: { "problems" => problems.size })
  elsif notes.any?
    ctx.unknown!(notes.join("; "), metrics: { "notes" => notes.size })
  else
    ctx.ok!("#{devices.size} InfiniBand port(s) healthy", metrics: { "ports" => devices.size })
  end
end
